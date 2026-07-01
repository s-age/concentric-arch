import Foundation

// MARK: - Builder

/// Builds a pipe left-to-right, UNIX-pipe style. `Cursor` is the type currently
/// flowing through the pipe; each `pipe(...)` advances it. The chain constraint
/// "previous Return == next Payload" is enforced by the method signatures:
/// `Symbol<Cursor, Next>` / `(Kernel, Cursor) -> Verb<Next>` will not type-check
/// unless the next stage consumes exactly what the current one produces.
public struct PipeBuilder<Input, Cursor> {
    let stages: [PipeStage]
    let inputType: String
    init(stages: [PipeStage], inputType: String) {
        self.stages = stages
        self.inputType = inputType
    }

    /// `internal` (not `private`) so the `fork` overloads in
    /// `PipeBuilder+Fork.swift` can append from their own file.
    func appending<Next>(_ stage: PipeStage) -> PipeBuilder<Input, Next> {
        PipeBuilder<Input, Next>(stages: stages + [stage], inputType: inputType)
    }

    /// Append a leaf `Symbol`. Its bound handler's verb drives the pipe directly:
    /// a plain handler flows through (`.next`), a verb-returning handler can
    /// `.abort`/`.divert`/`.fail` from here without any wrapper at this layer.
    public func pipe<Next>(_ symbol: Symbol<Cursor, Next>, file: String = #filePath, line: Int = #line) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .pipe, symbolID: symbol.id, flows: "\(Next.self)", description: symbol.description, wireSite: SourceLocation(file: file, line: line)),
            run: { kernel, value in try await kernel.invoke(symbol.id, value as! Cursor) }
        ))
    }

    /// Append a symbol whose payload is *built* from the current value, then flow
    /// its output. Bridges the common case where the next op's input is a struct
    /// assembled from the flowing value plus captured context (e.g. a pure
    /// transform taking `current` + the requested change), without dropping to a
    /// hand-rolled `kernel.call`. The symbol's verb still drives the pipe.
    public func pipe<SymbolInput, Next>(
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
    public func pipe<Next>(
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
    /// from the handler stops it). Lets a persist step read like a chain link:
    /// `pipeline(create).tap(save)`.
    public func tap(_ symbol: Symbol<Cursor, Void>, note: String? = nil, file: String = #filePath, line: Int = #line) -> PipeBuilder<Input, Cursor> {
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
    /// no I/O and no kernel calls (e.g. a DTO projection's `init(from:)`). Anonymous;
    /// pass `note:` to label the projection.
    public func map<Next>(note: String? = nil, file: String = #filePath, line: Int = #line, _ transform: @escaping @Sendable (Cursor) -> Next) -> PipeBuilder<Input, Next> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .map, symbolID: nil, flows: "\(Next.self)", description: note, wireSite: SourceLocation(file: file, line: line)),
            run: { _, value in .next(transform(value as! Cursor)) }
        ))
    }

    /// Effectful passthrough: run an effect on the value (e.g. a buffer write),
    /// then keep the same value flowing. Anonymous; pass `note:` to label the effect.
    public func effect(note: String? = nil, file: String = #filePath, line: Int = #line, _ run: @escaping @Sendable (Kernel, Cursor) async throws -> Void) -> PipeBuilder<Input, Cursor> {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .effect, symbolID: nil, flows: "\(Cursor.self)", description: note, wireSite: SourceLocation(file: file, line: line)),
            run: { kernel, value in
                try await run(kernel, value as! Cursor)
                return .next(value)
            }
        ))
    }

    /// Freeze the builder. `Output` is whatever is flowing now (`Cursor`).
    public func seal() -> Pipe<Input, Cursor> { Pipe(stages: stages, inputType: inputType) }
}

// MARK: - Entry points

/// Begin a pipeline with a leaf symbol. The pipe's `Input` is the symbol's
/// payload type; the symbol's bound handler supplies the first verb.
public func pipeline<P, O>(_ symbol: Symbol<P, O>, file: String = #filePath, line: Int = #line) -> PipeBuilder<P, O> {
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
public func pipeline<P, O>(
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
