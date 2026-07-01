import Foundation

// MARK: - Source location

/// Where a stage is *wired* in source — the exact file:line of the `.pipe`/`.map`/…
/// call in the saga, captured from `#filePath`/`#line` default arguments at build.
/// For an anonymous stage this is where its closure (its implementation) lives, so
/// the wiring graph can jump straight to it — past the protocol dead-end that
/// symbol-keyed dispatch otherwise leaves.
package struct SourceLocation: Sendable, Hashable {
    package let file: String   // absolute path (`#filePath`)
    package let line: Int
    package init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

// MARK: - Stage descriptor (static shape, for introspection)

/// The static shape of one pipe stage — the part that depends neither on the value
/// flowing nor on any captured payload. Each `PipeBuilder` method stamps it at
/// construction, so a built `Pipe` can be read back as a graph (`Pipe.descriptors`)
/// *without being run*. This is the data the wiring graph renders: the topology is
/// derived from the real pipelines, not hand-authored.
///
/// What is *not* here is what isn't static: the non-`.next` verbs a stage can emit
/// (`.fail`/`.abort`/`.divert`) live inside opaque closures / bound Drivers, and the
/// prose "what this part does" is a separate concern (symbol documentation). `.divert`
/// gets one deliberate exception (`divertsTo`, below): its actual target is runtime-
/// decided and can never be fully derived, but an author can still name the candidates.
package struct StageDescriptor: Sendable {
    /// Which builder method minted the stage — its role in the pipe.
    package enum Kind: String, Sendable {
        case pipe       // .pipe(symbol)
        case pipeAdapt  // .pipe(symbol) { adapt }
        case verb       // .pipe { -> Verb }  — anonymous self-describing stage
        case tap        // .tap(symbol)
        case map        // .map(transform)
        case effect     // .effect { ... }
        case fork       // .fork(...)
    }

    package let kind: Kind
    /// The dotted symbol id this stage invokes (`Layer.Device.method`), or `nil`
    /// for an anonymous stage (`verb`/`map`/`effect`).
    package let symbolID: String?
    /// Type name of the value leaving this stage — the label on its `.next` wire.
    package let flows: String
    /// "What this part does", lifted from the invoked `Symbol`'s `description`
    /// (which the `@callable` macro fills from the port method's doc comment).
    /// `nil` for an anonymous stage or an undocumented symbol.
    package let description: String?
    /// Where this stage is wired in source (the `.pipe`/`.map`/… call site in the
    /// saga). For anonymous stages this is where the closure — the implementation —
    /// lives; the wiring graph opens it directly.
    package let wireSite: SourceLocation?
    /// `.fork` only: each branch's own `descriptors` (it is a sub `Pipe`), in the
    /// order they were forked. Empty for every other kind.
    package let branches: [[StageDescriptor]]
    /// `.verb` only: dispatch keys (`WiringPipeline.key` form) this stage *might*
    /// `.divert` to, named by the author — unlike `branches`, this is not derived
    /// (the actual target is decided by a runtime condition inside the closure, so
    /// it can never be fully derived). Convention-level accuracy: a stale entry just
    /// fails to resolve to a real pipeline at render time. Empty for every other kind.
    package let divertsTo: [String]

    package init(kind: Kind, symbolID: String?, flows: String, description: String? = nil, wireSite: SourceLocation? = nil, branches: [[StageDescriptor]] = [], divertsTo: [String] = []) {
        self.kind = kind
        self.symbolID = symbolID
        self.flows = flows
        self.description = description
        self.wireSite = wireSite
        self.branches = branches
        self.divertsTo = divertsTo
    }
}

// MARK: - Erased stage

/// One pipeline step: its static `descriptor` plus the type-erased `run` closure.
/// The erasure is safe because construction (`PipeBuilder.pipe`) pins both ends via
/// the `Symbol` / `Verb<Next>` signatures — the same discipline as `KernelBuilder`'s
/// `as!`.
struct PipeStage {
    let descriptor: StageDescriptor
    let run: @Sendable (Kernel, Any) async throws -> Verb<Any>
}

// MARK: - Pipe

/// A sealed pipeline: a list of stages whose phantom `Input`/`Output` pin the
/// payload you feed in and the result you get back. Built by `PipeBuilder`,
/// run by `Kernel.compose`.
///
/// `@unchecked Sendable`: the stored state is an array of stages (each an
/// `@Sendable` closure plus a `Sendable` descriptor — safe to share) and the
/// input type name; `Input`/`Output` are phantom and hold no value, so they impose
/// no `Sendable` requirement of their own.
package struct Pipe<Input, Output>: @unchecked Sendable {
    let stages: [PipeStage]
    /// Type name of the payload that enters the pipe (`Input`).
    package let inputType: String
    /// The static shape of the pipe, stage by stage — what the wiring graph reads.
    package var descriptors: [StageDescriptor] { stages.map(\.descriptor) }

    init(stages: [PipeStage], inputType: String) {
        self.stages = stages
        self.inputType = inputType
    }
}

// MARK: - Builder

/// Builds a pipe left-to-right, UNIX-pipe style. `Cursor` is the type currently
/// flowing through the pipe; each `pipe(...)` advances it. The chain constraint
/// "previous Return == next Payload" is enforced by the method signatures:
/// `Symbol<Cursor, Next>` / `(Kernel, Cursor) -> Verb<Next>` will not type-check
/// unless the next stage consumes exactly what the current one produces.
package struct PipeBuilder<Input, Cursor> {
    let stages: [PipeStage]
    let inputType: String
    init(stages: [PipeStage], inputType: String) {
        self.stages = stages
        self.inputType = inputType
    }

    private func appending<Next>(_ stage: PipeStage) -> PipeBuilder<Input, Next> {
        PipeBuilder<Input, Next>(stages: stages + [stage], inputType: inputType)
    }

    /// Append a leaf `Symbol`. Its bound handler's verb drives the pipe directly:
    /// a plain handler flows through (`.next`), a verb-returning Driver can
    /// `.abort`/`.divert`/`.fail` from here without any wrapper at this layer.
    package func pipe<Next>(_ symbol: Symbol<Cursor, Next>, file: String = #filePath, line: Int = #line) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .pipe, symbolID: symbol.id, flows: "\(Next.self)", description: symbol.description, wireSite: SourceLocation(file: file, line: line)),
            run: { kernel, value in try await kernel.invoke(symbol.id, value as! Cursor) }
        ))
    }

    /// Append a symbol whose payload is *built* from the current value, then flow
    /// its output. Bridges the common case where the next op's input is a struct
    /// assembled from the flowing value plus captured context (e.g. a Compute op
    /// taking `current` + the requested change), without dropping to a hand-rolled
    /// `kernel.call`. The symbol's verb still drives the pipe.
    package func pipe<SymbolInput, Next>(
        _ symbol: Symbol<SymbolInput, Next>,
        file: String = #filePath,
        line: Int = #line,
        _ adapt: @escaping @Sendable (Cursor) -> SymbolInput
    ) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .pipeAdapt, symbolID: symbol.id, flows: "\(Next.self)", description: symbol.description, wireSite: SourceLocation(file: file, line: line)),
            run: { kernel, value in try await kernel.invoke(symbol.id, adapt(value as! Cursor)) }
        ))
    }

    /// Append a verb-returning stage — the self-describing rule. It receives the
    /// kernel (to make its own calls) and the flowing value, and decides
    /// `.next`/`.abort`/`.divert`/`.fail`. Anonymous (no symbol), so it carries no
    /// description of its own — pass `note:` to label what this guard/rule does.
    /// `divertsTo:` optionally names the dispatch key(s) this stage might `.divert`
    /// to — the wiring graph renders them as jump links; see `StageDescriptor.divertsTo`.
    package func pipe<Next>(
        note: String? = nil,
        divertsTo: [String] = [],
        file: String = #filePath,
        line: Int = #line,
        _ stage: @escaping @Sendable (Kernel, Cursor) async throws -> Verb<Next>
    ) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .verb, symbolID: nil, flows: "\(Next.self)", description: note, wireSite: SourceLocation(file: file, line: line), divertsTo: divertsTo),
            run: { kernel, value in try await stage(kernel, value as! Cursor).erased() }
        ))
    }

    /// Run a side-effecting symbol on the current value and keep that value
    /// flowing — a pipe "tap"/"tee". The symbol's `Void` output is discarded so
    /// the cursor is unchanged, but its verb still governs the pipe (a `.fail`
    /// from the Driver stops it). Lets a persist step read like a chain link:
    /// `pipeline(create).tap(save)`.
    package func tap(_ symbol: Symbol<Cursor, Void>, note: String? = nil, file: String = #filePath, line: Int = #line) -> PipeBuilder<Input, Cursor> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .tap, symbolID: symbol.id, flows: "\(Cursor.self)", description: note ?? symbol.description, wireSite: SourceLocation(file: file, line: line)),
            run: { kernel, value in
                switch try await kernel.invoke(symbol.id, value as! Cursor) {
                case .next: return .next(value)            // discard Void, forward the original
                case .abort(let result): return .abort(result)
                case .divert(let diversion): return .divert(diversion)
                case .fail(let error): return .fail(error)
                }
            }
        ))
    }

    /// Pure synchronous transform of the flowing value — a projection step with
    /// no I/O and no kernel calls (e.g. `SlideshowReturn.init(from:)`). Anonymous;
    /// pass `note:` to label the projection.
    package func map<Next>(note: String? = nil, file: String = #filePath, line: Int = #line, _ transform: @escaping @Sendable (Cursor) -> Next) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .map, symbolID: nil, flows: "\(Next.self)", description: note, wireSite: SourceLocation(file: file, line: line)),
            run: { _, value in .next(transform(value as! Cursor)) }
        ))
    }

    /// Effectful passthrough: run an effect on the value (e.g. a buffer write),
    /// then keep the same value flowing. Anonymous; pass `note:` to label the effect.
    package func effect(note: String? = nil, file: String = #filePath, line: Int = #line, _ run: @escaping @Sendable (Kernel, Cursor) async throws -> Void) -> PipeBuilder<Input, Cursor> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .effect, symbolID: nil, flows: "\(Cursor.self)", description: note, wireSite: SourceLocation(file: file, line: line)),
            run: { kernel, value in
                try await run(kernel, value as! Cursor)
                return .next(value)
            }
        ))
    }

    /// Freeze the builder. `Output` is whatever is flowing now (`Cursor`).
    package func seal() -> Pipe<Input, Cursor> { Pipe(stages: stages, inputType: inputType) }
}

// MARK: - Fork (parallel fan-out, `Promise.all`-style)

extension PipeBuilder {
    /// Fan the current value out to N independent branches (each a sealed sub
    /// `Pipe` run via `kernel.compose`), run them concurrently, and collect
    /// their results into an order-preserving tuple. `.map`/`.pipe` on the
    /// tuple output is the "transistor" that recombines the branches — no
    /// dedicated combinator is needed.
    ///
    /// Fail-fast via structured concurrency: `async let` cancels any
    /// not-yet-awaited sibling the moment this closure's scope exits (whether
    /// by returning or by throwing), so a failing branch stops the others
    /// without extra bookkeeping. `(try await r1, try await r2)` awaits
    /// left-to-right, so the propagated error is the first one *awaited*, not
    /// necessarily the first one that failed in wall-clock time.
    ///
    /// Requires `Sendable` on `Cursor` and every `Ri`: unlike the sequential
    /// stages above, this one actually crosses a concurrency boundary
    /// (`async let`), so Swift must be able to prove the values are safe to
    /// hand to a child task and back.
    package func fork<R1: Sendable, R2: Sendable>(
        _ b1: Pipe<Cursor, R1>,
        _ b2: Pipe<Cursor, R2>,
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, (R1, R2)> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "(\(R1.self), \(R2.self))", description: note, wireSite: SourceLocation(file: file, line: line), branches: [b1.descriptors, b2.descriptors]),
            run: { kernel, value in
                let cursor = value as! Cursor
                async let r1 = kernel.compose(b1, cursor)
                async let r2 = kernel.compose(b2, cursor)
                return .next((try await r1, try await r2))
            }
        ))
    }

    /// Three-branch overload — see the two-branch `fork` for the shared design notes.
    package func fork<R1: Sendable, R2: Sendable, R3: Sendable>(
        _ b1: Pipe<Cursor, R1>,
        _ b2: Pipe<Cursor, R2>,
        _ b3: Pipe<Cursor, R3>,
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, (R1, R2, R3)> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "(\(R1.self), \(R2.self), \(R3.self))", description: note, wireSite: SourceLocation(file: file, line: line), branches: [b1.descriptors, b2.descriptors, b3.descriptors]),
            run: { kernel, value in
                let cursor = value as! Cursor
                async let r1 = kernel.compose(b1, cursor)
                async let r2 = kernel.compose(b2, cursor)
                async let r3 = kernel.compose(b3, cursor)
                return .next((try await r1, try await r2, try await r3))
            }
        ))
    }

    /// Four-branch overload — see the two-branch `fork` for the shared design notes.
    package func fork<R1: Sendable, R2: Sendable, R3: Sendable, R4: Sendable>(
        _ b1: Pipe<Cursor, R1>,
        _ b2: Pipe<Cursor, R2>,
        _ b3: Pipe<Cursor, R3>,
        _ b4: Pipe<Cursor, R4>,
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, (R1, R2, R3, R4)> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "(\(R1.self), \(R2.self), \(R3.self), \(R4.self))", description: note, wireSite: SourceLocation(file: file, line: line), branches: [b1.descriptors, b2.descriptors, b3.descriptors, b4.descriptors]),
            run: { kernel, value in
                let cursor = value as! Cursor
                async let r1 = kernel.compose(b1, cursor)
                async let r2 = kernel.compose(b2, cursor)
                async let r3 = kernel.compose(b3, cursor)
                async let r4 = kernel.compose(b4, cursor)
                return .next((try await r1, try await r2, try await r3, try await r4))
            }
        ))
    }

    /// Homogeneous, unbounded fan-out: same branch type repeated N times,
    /// collected into an order-preserving array. Escape hatch for arities
    /// beyond the tuple overloads above (2...4) or a true variable-length
    /// fan-out. `async let` can't express a dynamic arity, so this uses
    /// `withThrowingTaskGroup` instead — each child tags its result with its
    /// index so the array can be reassembled in submission order regardless
    /// of completion order. A child's throw cancels the rest of the group and
    /// propagates once the group finishes unwinding (the same structured-
    /// concurrency guarantee the tuple overloads get from `async let`).
    package func fork<R: Sendable>(
        _ branches: [Pipe<Cursor, R>],
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, [R]> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "[\(R.self)]", description: note, wireSite: SourceLocation(file: file, line: line), branches: branches.map(\.descriptors)),
            run: { kernel, value in
                let cursor = value as! Cursor
                let results = try await withThrowingTaskGroup(of: (Int, R).self) { group -> [R] in
                    for (index, branch) in branches.enumerated() {
                        group.addTask { (index, try await kernel.compose(branch, cursor)) }
                    }
                    var collected = [R?](repeating: nil, count: branches.count)
                    for try await (index, result) in group {
                        collected[index] = result
                    }
                    return collected.map { $0! }
                }
                return .next(results)
            }
        ))
    }
}

// MARK: - Entry points

/// Begin a pipeline with a leaf symbol. The pipe's `Input` is the symbol's
/// payload type; the symbol's bound handler supplies the first verb.
package func pipeline<P, O>(_ symbol: Symbol<P, O>, file: String = #filePath, line: Int = #line) -> PipeBuilder<P, O> {
    PipeBuilder<P, O>(
        stages: [PipeStage(
            descriptor: StageDescriptor(kind: .pipe, symbolID: symbol.id, flows: "\(O.self)", description: symbol.description, wireSite: SourceLocation(file: file, line: line)),
            run: { kernel, value in try await kernel.invoke(symbol.id, value as! P) }
        )],
        inputType: "\(P.self)"
    )
}

/// Begin a pipeline with a verb-returning stage. Anonymous; pass `note:` to label it.
/// `divertsTo:` optionally names the dispatch key(s) this stage might `.divert` to —
/// see `StageDescriptor.divertsTo`.
package func pipeline<P, O>(
    note: String? = nil,
    divertsTo: [String] = [],
    file: String = #filePath,
    line: Int = #line,
    _ stage: @escaping @Sendable (Kernel, P) async throws -> Verb<O>
) -> PipeBuilder<P, O> {
    PipeBuilder<P, O>(
        stages: [PipeStage(
            descriptor: StageDescriptor(kind: .verb, symbolID: nil, flows: "\(O.self)", description: note, wireSite: SourceLocation(file: file, line: line), divertsTo: divertsTo),
            run: { kernel, value in try await stage(kernel, value as! P).erased() }
        )],
        inputType: "\(P.self)"
    )
}

// MARK: - Running

extension Kernel {
    /// Thread `payload` through `stages`, interpreting each verb. `.next` hands
    /// the value to the next stage; `.abort` returns it; `.fail` throws.
    /// `.divert` **replaces** `stages`/`value` with the target pipe's own and
    /// restarts from its first stage — an iteration, not a recursive `compose`
    /// call. That is the whole point: a pipe that ends by diverting back to a
    /// pipe shaped like itself (an agent loop, a stream-processing loop) costs
    /// O(1) stack frames no matter how many hops it takes, because there is
    /// never a nested async call to unwind — each hop discards the previous
    /// one's stage list outright rather than waiting on it.
    private func runStages(_ initialStages: [PipeStage], _ initialPayload: Any) async throws -> Any {
        var stages = initialStages
        var value = initialPayload
        var index = 0
        while index < stages.count {
            switch try await stages[index].run(self, value) {
            case .next(let forward):
                value = forward
                index += 1
            case .abort(let result):
                return result
            case .divert(let diversion):
                stages = diversion.stages
                value = diversion.payload
                index = 0
            case .fail(let error):
                throw error
            }
        }
        return value
    }

    /// Run a sealed pipe and cast its final (or `.abort`/diverted-to) value to
    /// the pipe's declared `Output` — the single boundary cast every terminator
    /// passes through exactly once.
    package func compose<I, O>(_ pipe: Pipe<I, O>, _ payload: I) async throws -> O {
        try await composeCast(runStages(pipe.stages, payload), to: O.self)
    }

    /// Convenience: seal and run a builder in one step.
    package func compose<I, O>(_ builder: PipeBuilder<I, O>, _ payload: I) async throws -> O {
        try await compose(builder.seal(), payload)
    }

    /// Forward-only drive: run the pipe for its effects and in-pipe verbs, then
    /// discard the final value — there is no return path. Results are
    /// published through `.tap`/`.effect` (buffer writes); only
    /// `.next`/`.abort`/`.divert`/`.fail` steer the flow. Because nothing is
    /// returned, `.abort`/`.divert` carry no output type and the boundary cast
    /// that `compose` performs disappears entirely.
    package func run<I, O>(_ pipe: Pipe<I, O>, _ payload: I) async throws {
        _ = try await runStages(pipe.stages, payload)
    }

    /// Convenience: seal and forward-drive a builder in one step.
    package func run<I, O>(_ builder: PipeBuilder<I, O>, _ payload: I) async throws {
        try await run(builder.seal(), payload)
    }

    /// Interpret a single verb down to a typed result — the terminal step shared
    /// by `call` (a one-stage pipe) and `compose`'s terminators. `.next`/`.abort`
    /// yield their value; `.divert` runs the other pipe (via the same iterative
    /// `runStages`, so a diverted-to loop is still O(1) stack); `.fail` throws.
    func interpret<O>(_ verb: Verb<Any>, as _: O.Type) async throws -> O {
        switch verb {
        case .next(let forward): return try composeCast(forward, to: O.self)
        case .abort(let result): return try composeCast(result, to: O.self)
        case .divert(let diversion): return try composeCast(await runStages(diversion.stages, diversion.payload), to: O.self)
        case .fail(let error): throw error
        }
    }
}

/// The single boundary cast for a terminator's value. `.next` payloads are
/// `Symbol`-pinned and never pass through here; only the pipe's final result
/// does, so a mismatch is a programmer error in a `.abort`/`.divert` — surfaced
/// as a throw rather than a `as!` trap.
private func composeCast<T>(_ value: Any, to _: T.Type) throws -> T {
    if T.self == Void.self { return () as! T }
    if let typed = value as? T { return typed }
    throw KernelError.composeTypeMismatch(expected: "\(T.self)", actual: "\(type(of: value))")
}
