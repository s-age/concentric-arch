import Foundation
import Synchronization

/// How `dispatch` treats a command that is identical to one already queued or
/// running on the bus.
///
/// `dropIfPending` is the default: identical, accidental re-fires (a double-click,
/// a `.task(id:)` re-run, two call sites asking for the same thing) collapse to
/// one — the *first* wins, the rest are dropped. The key is the symbol plus the
/// payload value, so a genuinely different payload is never coalesced. The window
/// is "queued ∪ running": once the command completes its key is freed, so a later
/// identical command (e.g. re-opening a slideshow after the player loaded another)
/// runs fresh.
///
/// `repeatable` opts out — every dispatch runs. Use it for non-idempotent /
/// intentionally-repeatable commands where a second identical call must not be
/// swallowed (an increment, an append, "send again"). Coalescing is the default
/// because the accidental-duplicate case is by far the common one here, and a
/// drop is never silent: it is recorded in the trace.
package enum Coalesce: Sendable, Equatable {
    case dropIfPending
    case repeatable
}

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

    /// Keys of commands currently queued or running. The dedup window for
    /// `enqueue(key:)`; a key is freed when its command completes.
    private let pending = Mutex<Set<String>>([])

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

    /// Coalescing enqueue: drop the work if an identical `key` is already queued or
    /// running, otherwise enqueue it and free the key when it completes. Returns
    /// `false` when the command was dropped (the caller records that in the trace).
    @discardableResult
    func enqueue(key: String, _ work: @escaping @Sendable () async -> Void) -> Bool {
        let accepted = pending.withLock { $0.insert(key).inserted }
        guard accepted else { return false }
        continuation.yield { [self] in
            await work()
            pending.withLock { _ = $0.remove(key) }
        }
        return true
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
