import Foundation

/// A serial, fire-and-forget command queue — the "mutex" behind `Kernel.dispatch`.
///
/// `enqueue` returns immediately (the caller's stack stays shallow); the work
/// runs on one long-lived drain task, strictly one at a time in submission
/// order. That ordering is the point: two commands fired back to back never
/// interleave, so an authoritative reload can't race a create that was
/// submitted just before it. Each work item owns its own error handling — the
/// bus only sequences.
final class CommandBus: Sendable {
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
        self.continuation = continuation
        Task {
            for await work in stream { await work() }
        }
    }

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        continuation.yield(work)
    }
}
