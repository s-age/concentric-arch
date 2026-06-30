import Foundation

// MARK: - Stage descriptor (static shape, for introspection)

/// The static shape of one pipe stage — the part that depends neither on the value
/// flowing nor on any captured payload. Each `PipeBuilder` method stamps it at
/// construction, so a built `Pipe` can be read back as a graph (`Pipe.descriptors`)
/// *without being run*. This is the data the wiring graph renders: the topology is
/// derived from the real pipelines, not hand-authored.
///
/// What is *not* here is what isn't static: the non-`.next` verbs a stage can emit
/// (`.fail`/`.abort`/`.divert`) live inside opaque closures / bound Drivers, and the
/// prose "what this part does" is a separate concern (symbol documentation).
package struct StageDescriptor: Sendable {
    /// Which builder method minted the stage — its role in the pipe.
    package enum Kind: String, Sendable {
        case pipe       // .pipe(symbol)
        case pipeAdapt  // .pipe(symbol) { adapt }
        case verb       // .pipe { -> Verb }  — anonymous self-describing stage
        case tap        // .tap(symbol)
        case map        // .map(transform)
        case effect     // .effect { ... }
    }

    package let kind: Kind
    /// The dotted symbol id this stage invokes (`Layer.Device.method`), or `nil`
    /// for an anonymous stage (`verb`/`map`/`effect`).
    package let symbolID: String?
    /// Type name of the value leaving this stage — the label on its `.next` wire.
    package let flows: String

    package init(kind: Kind, symbolID: String?, flows: String) {
        self.kind = kind
        self.symbolID = symbolID
        self.flows = flows
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
    package func pipe<Next>(_ symbol: Symbol<Cursor, Next>) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .pipe, symbolID: symbol.id, flows: "\(Next.self)"),
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
        _ adapt: @escaping @Sendable (Cursor) -> SymbolInput
    ) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .pipeAdapt, symbolID: symbol.id, flows: "\(Next.self)"),
            run: { kernel, value in try await kernel.invoke(symbol.id, adapt(value as! Cursor)) }
        ))
    }

    /// Append a verb-returning stage — the self-describing rule. It receives the
    /// kernel (to make its own calls) and the flowing value, and decides
    /// `.next`/`.abort`/`.divert`/`.fail`.
    package func pipe<Next>(
        _ stage: @escaping @Sendable (Kernel, Cursor) async throws -> Verb<Next>
    ) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .verb, symbolID: nil, flows: "\(Next.self)"),
            run: { kernel, value in try await stage(kernel, value as! Cursor).erased() }
        ))
    }

    /// Run a side-effecting symbol on the current value and keep that value
    /// flowing — a pipe "tap"/"tee". The symbol's `Void` output is discarded so
    /// the cursor is unchanged, but its verb still governs the pipe (a `.fail`
    /// from the Driver stops it). Lets a persist step read like a chain link:
    /// `pipeline(create).tap(save)`.
    package func tap(_ symbol: Symbol<Cursor, Void>) -> PipeBuilder<Input, Cursor> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .tap, symbolID: symbol.id, flows: "\(Cursor.self)"),
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
    /// no I/O and no kernel calls (e.g. `SlideshowReturn.init(from:)`).
    package func map<Next>(_ transform: @escaping @Sendable (Cursor) -> Next) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .map, symbolID: nil, flows: "\(Next.self)"),
            run: { _, value in .next(transform(value as! Cursor)) }
        ))
    }

    /// Effectful passthrough: run an effect on the value (e.g. a buffer write),
    /// then keep the same value flowing.
    package func effect(_ run: @escaping @Sendable (Kernel, Cursor) async throws -> Void) -> PipeBuilder<Input, Cursor> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .effect, symbolID: nil, flows: "\(Cursor.self)"),
            run: { kernel, value in
                try await run(kernel, value as! Cursor)
                return .next(value)
            }
        ))
    }

    /// Freeze the builder. `Output` is whatever is flowing now (`Cursor`).
    package func seal() -> Pipe<Input, Cursor> { Pipe(stages: stages, inputType: inputType) }
}

// MARK: - Entry points

/// Begin a pipeline with a leaf symbol. The pipe's `Input` is the symbol's
/// payload type; the symbol's bound handler supplies the first verb.
package func pipeline<P, O>(_ symbol: Symbol<P, O>) -> PipeBuilder<P, O> {
    PipeBuilder<P, O>(
        stages: [PipeStage(
            descriptor: StageDescriptor(kind: .pipe, symbolID: symbol.id, flows: "\(O.self)"),
            run: { kernel, value in try await kernel.invoke(symbol.id, value as! P) }
        )],
        inputType: "\(P.self)"
    )
}

/// Begin a pipeline with a verb-returning stage.
package func pipeline<P, O>(
    _ stage: @escaping @Sendable (Kernel, P) async throws -> Verb<O>
) -> PipeBuilder<P, O> {
    PipeBuilder<P, O>(
        stages: [PipeStage(
            descriptor: StageDescriptor(kind: .verb, symbolID: nil, flows: "\(O.self)"),
            run: { kernel, value in try await stage(kernel, value as! P).erased() }
        )],
        inputType: "\(P.self)"
    )
}

// MARK: - Running

extension Kernel {
    /// Run a sealed pipe: thread `payload` through each stage, interpreting the
    /// verb it returns. `.next` hands the value to the next stage; `.abort`
    /// returns it; `.divert` runs the other pipe and returns that; `.fail`
    /// throws. Falling off the end returns the last `.next` value.
    package func compose<I, O>(_ pipe: Pipe<I, O>, _ payload: I) async throws -> O {
        var value: Any = payload
        for stage in pipe.stages {
            switch try await stage.run(self, value) {
            case .next(let forward):
                value = forward
            case .abort(let result):
                return try composeCast(result, to: O.self)
            case .divert(let diversion):
                return try composeCast(await diversion.execute(self), to: O.self)
            case .fail(let error):
                throw error
            }
        }
        return try composeCast(value, to: O.self)
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
        var value: Any = payload
        for stage in pipe.stages {
            switch try await stage.run(self, value) {
            case .next(let forward): value = forward
            case .abort: return
            case .divert(let diversion): _ = try await diversion.execute(self); return
            case .fail(let error): throw error
            }
        }
    }

    /// Convenience: seal and forward-drive a builder in one step.
    package func run<I, O>(_ builder: PipeBuilder<I, O>, _ payload: I) async throws {
        try await run(builder.seal(), payload)
    }

    /// Interpret a single verb down to a typed result — the terminal step shared
    /// by `call` (a one-stage pipe) and `compose`'s terminators. `.next`/`.abort`
    /// yield their value; `.divert` runs the other pipe; `.fail` throws.
    func interpret<O>(_ verb: Verb<Any>, as _: O.Type) async throws -> O {
        switch verb {
        case .next(let forward): return try composeCast(forward, to: O.self)
        case .abort(let result): return try composeCast(result, to: O.self)
        case .divert(let diversion): return try composeCast(await diversion.execute(self), to: O.self)
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
