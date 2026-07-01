import Foundation

// MARK: - Verb

/// The control word a pipeline stage returns instead of a bare value.
///
/// Mental model: UNIX pipe. `.next` is the implicit "write to stdout, keep
/// flowing"; the other three are explicit terminators. Only `.next` *feeds a
/// downstream stage*, so only `.next` carries a statically-pinned `Forward`
/// type (the next stage's payload — see `PipeBuilder.pipe`). The terminators
/// discard the rest of the pipe, so their value never lands in a typed payload
/// slot; it leaves once, through `compose`'s single boundary cast. That is why
/// they can be erased to `Any` without losing any guarantee that ever existed.
package enum Verb<Forward> {
    /// Continue: `Forward` becomes the next stage's payload.
    case next(Forward)
    /// Normal early termination: stop here, this value is the pipe's result.
    case abort(Any)
    /// Drop the remaining stages and run another pipe instead; its result
    /// becomes this pipe's result.
    case divert(Diversion)
    /// Abnormal termination: throw out of `compose`.
    case fail(Error)
}

extension Verb {
    /// Erase the forward type for storage in the kernel's handler table. Only
    /// `.next` carries a typed payload; the terminators already hold `Any`.
    func erased() -> Verb<Any> {
        switch self {
        case .next(let forward): return .next(forward)
        case .abort(let result): return .abort(result)
        case .divert(let diversion): return .divert(diversion)
        case .fail(let error): return .fail(error)
        }
    }
}

// MARK: - Diversion

/// A fully-formed "jump target" for `.divert`: another pipe's stages plus the
/// payload to start it with, packaged so the running pipe needn't know its
/// input type. Deliberately plain data (not a closure over `Kernel`) — this is
/// what lets `compose`/`run` splice a diverted-to pipe straight into their own
/// stage-iteration loop and keep going, rather than recursing into a nested
/// `compose` call. A pipe that `.divert`s back to a pipe shaped like itself
/// (an agent/stream-processing loop) costs O(1) stack frames this way, no
/// matter how many hops the loop takes.
///
/// The output is erased to `Any` here and re-checked at `compose`'s boundary,
/// exactly like every other terminator — the diverted pipe's result is never
/// consumed by an upstream stage, so there is no chain constraint to enforce.
///
/// `@unchecked Sendable`: same discipline as `Pipe` — `stages` is an array of
/// `@Sendable` closures plus `Sendable` descriptors, and `payload`'s concrete
/// type was pinned `Sendable` by the generic initializer before being erased
/// to `Any` here.
package struct Diversion: @unchecked Sendable {
    let stages: [PipeStage]
    let payload: Any

    package init<I: Sendable, O>(_ pipe: Pipe<I, O>, _ payload: I) {
        self.stages = pipe.stages
        self.payload = payload
    }
}
