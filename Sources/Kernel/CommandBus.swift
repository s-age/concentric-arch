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
    private let gate = PauseGate()

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self)
        self.continuation = continuation
        let gate = self.gate
        Task {
            for await work in stream {
                await gate.waitWhileSuspended()
                await work()
            }
        }
    }

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        continuation.yield(work)
    }

    /// DEBUG time-travel: stop draining new commands so a restored past state isn't
    /// clobbered while previewed. The command currently running (if any) finishes;
    /// queued ones wait. Fire-and-forget — the suspend lands a turn later, which is
    /// benign because preview also blocks user input.
    func suspend() { Task { [gate] in await gate.set(suspended: true) } }
    func resumeDraining() { Task { [gate] in await gate.set(suspended: false) } }
}

/// Serializes the drain's pause flag and the waiters parked on it. An actor so
/// `suspend`/`resume` and the drain's `waitWhileSuspended` can't race the flag.
private actor PauseGate {
    private var suspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set(suspended value: Bool) {
        suspended = value
        if !value {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    func waitWhileSuspended() async {
        guard suspended else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
