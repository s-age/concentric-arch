import Foundation

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
/// as a throw rather than a `as!` trap. File-level `private`: it must live in
/// the same file as `compose`/`interpret`, its only callers.
private func composeCast<T>(_ value: Any, to _: T.Type) throws -> T {
    if T.self == Void.self { return () as! T }
    if let typed = value as? T { return typed }
    throw KernelError.composeTypeMismatch(expected: "\(T.self)", actual: "\(type(of: value))")
}
