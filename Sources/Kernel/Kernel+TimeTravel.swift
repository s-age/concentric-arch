#if DEBUG
import Foundation

// Replaying a past buffer state — the time-travel side of the DEBUG monitor.
// Restore is the one operation that runs *backward*, so it is fenced here as a
// DEBUG affordance, not a core capability.

extension Kernel {
    /// Preview a past snapshot: write its `image` into the live buffer so the app
    /// renders the past. Visual only — infra (SwiftData) is untouched, so the
    /// caller must also block input (the main window disables itself behind a
    /// banner).
    ///
    /// Enter-or-scrub: the *first* call stashes the real present and freezes the
    /// command bus; later calls (selection moved to another flow) just swap in the
    /// new image. Re-stashing on a scrub would capture the *displayed past* as the
    /// present, so the stash is taken once and held until `exitTimeTravel`.
    ///
    /// Suspends and waits for the bus to go idle *before* capturing: a command
    /// that was already running (or queued) when preview was entered still gets
    /// to finish and write the buffer, and the stash reflects that write instead
    /// of losing it to the following `restore`.
    @MainActor
    public func previewTimeTravel(root: UUID, image: BufferImage) async {
        if buffer.read(TimeTravelState.self).stashedPresent == nil {
            await commands.suspendAndWaitUntilIdle()
            let present = buffer.capture(Set(image.keys))
            buffer.mutate(TimeTravelState.self) { $0.stashedPresent = present }
        }
        buffer.restore(image)
        buffer.mutate(TimeTravelState.self) { $0.previewRoot = root }
    }

    /// Leave the preview: put the stashed present back and resume command draining.
    /// No-op if no preview is active.
    @MainActor
    public func exitTimeTravel() {
        guard let present = buffer.read(TimeTravelState.self).stashedPresent else { return }
        buffer.restore(present)
        commands.resumeDraining()
        buffer.mutate(TimeTravelState.self) {
            $0.previewRoot = nil
            $0.stashedPresent = nil
        }
    }
}
#endif
