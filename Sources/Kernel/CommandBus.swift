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
                await gate.beginWorkUnlessSuspended()
                await work()
                await gate.endWork()
            }
        }
    }

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        continuation.yield(work)
    }

    /// DEBUG time-travel: stop draining new commands and wait until any command
    /// that was already running (or that starts in the window this races
    /// against) has finished, so a `buffer.capture` taken right after this
    /// returns can't miss a write still in flight. Queued-but-not-started
    /// commands stay parked until `resumeDraining()`. Awaiting this (rather than
    /// the old fire-and-forget suspend) is what closes the capture/suspend race.
    func suspendAndWaitUntilIdle() async {
        await gate.suspendAndWaitUntilIdle()
    }

    /// Resuming doesn't need to be awaited — nothing depends on it "having
    /// landed" before the caller proceeds.
    func resumeDraining() { Task { [gate] in await gate.set(suspended: false) } }
}

/// Serializes the drain's pause flag, the in-flight marker, and the waiters
/// parked on either. An actor so the drain loop's begin/end-of-work bracket and
/// `suspendAndWaitUntilIdle`'s check-then-wait can't race: each method flips its
/// flag and inspects the other's without an intervening `await`, so whichever
/// side reaches the actor first, the other sees a consistent picture — either
/// the next item finds `suspended` already true and parks before running, or
/// `suspendAndWaitUntilIdle` finds `isWorking` already true and waits for it.
private actor PauseGate {
    private var suspended = false
    private var isWorking = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func set(suspended value: Bool) {
        suspended = value
        if !value {
            for waiter in resumeWaiters { waiter.resume() }
            resumeWaiters.removeAll()
        }
    }

    /// Drain-loop bracket, called before each work item: parks while suspended,
    /// then — with no `await` between the check and the flip — marks the item as
    /// in flight so a concurrent `suspendAndWaitUntilIdle` can't miss it.
    func beginWorkUnlessSuspended() async {
        while suspended {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        isWorking = true
    }

    /// Drain-loop bracket, called once a work item returns.
    func endWork() {
        isWorking = false
        for waiter in idleWaiters { waiter.resume() }
        idleWaiters.removeAll()
    }

    func suspendAndWaitUntilIdle() async {
        suspended = true
        guard isWorking else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}
