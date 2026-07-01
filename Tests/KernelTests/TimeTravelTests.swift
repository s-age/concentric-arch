#if DEBUG
import Foundation
import Testing
@testable import Kernel

// MARK: - Time-travel preview (DEBUG: enter/exit round-trip)

/// A throwaway app state — any value type works as a buffer cell.
private struct Counter { var n: Int }

@MainActor
@Test
func timeTravelScrubsBetweenPastsThenRestoresPresentOnExit() async {
    let bufferBuilder = BufferBuilder()
    bufferBuilder.allocate(Counter(n: 0))
    bufferBuilder.allocate(TimeTravelState())
    let buffer = bufferBuilder.build()
    let kernel = KernelBuilder().build(buffer: buffer)
    let key = ObjectIdentifier(Counter.self)

    // Two past images (n == 1, then n == 2)…
    buffer.mutate(Counter.self) { $0.n = 1 }
    let imageA = buffer.capture([key])
    buffer.mutate(Counter.self) { $0.n = 2 }
    let imageB = buffer.capture([key])

    // …then move on to the present (n == 9).
    buffer.mutate(Counter.self) { $0.n = 9 }
    #expect(buffer.read(Counter.self).n == 9)

    // First preview enters and reflects A.
    let rootA = UUID(), rootB = UUID()
    await kernel.previewTimeTravel(root: rootA, image: imageA)
    #expect(buffer.read(Counter.self).n == 1)
    #expect(buffer.read(TimeTravelState.self).previewRoot == rootA)

    // Selecting another flow scrubs to B — without re-stashing, so exit must still
    // land on the original present (9), not on a previewed past (1).
    await kernel.previewTimeTravel(root: rootB, image: imageB)
    #expect(buffer.read(Counter.self).n == 2)
    #expect(buffer.read(TimeTravelState.self).previewRoot == rootB)

    kernel.exitTimeTravel()
    #expect(buffer.read(Counter.self).n == 9)
    #expect(buffer.read(TimeTravelState.self).previewRoot == nil)
}

// MARK: - Capture/suspend race (#28)

/// A one-shot open/wait latch, used to pin down the interleaving of a dispatched
/// command against `previewTimeTravel` without relying on timing.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A command dispatched *before* preview is entered must still be allowed to
/// finish and have its write survive the stash: `previewTimeTravel` suspends the
/// bus and waits for the in-flight command to settle before capturing, so the
/// stash — and everything restored from it on exit — reflects the write instead
/// of the pre-command state.
@MainActor
@Test
func inFlightCommandAtEntrySurvivesThePreviewStash() async {
    let bufferBuilder = BufferBuilder()
    bufferBuilder.allocate(Counter(n: 0))
    bufferBuilder.allocate(TimeTravelState())
    let buffer = bufferBuilder.build()

    let started = Latch()
    let proceed = Latch()
    let slowWrite = Symbol<Void, Void>("test.timeTravelRace.slowWrite")
    let builder = KernelBuilder()
    builder.register(slowWrite) { (_: Void) async -> Void in
        await started.open()
        await proceed.wait()
        await MainActor.run { buffer.mutate(Counter.self) { $0.n += 1 } }
    }
    let kernel = builder.build(buffer: buffer)
    let key = ObjectIdentifier(Counter.self)

    // A past image, captured before the write below — distinct from both the
    // pre-write and post-write present, so each phase of the test is unambiguous.
    let past = buffer.capture([key])

    kernel.dispatch(slowWrite, ())
    await started.wait() // the command is now in flight, hasn't written yet

    let preview = Task { @MainActor in
        await kernel.previewTimeTravel(root: UUID(), image: past)
    }

    // Let the in-flight command finish its write only after preview has begun
    // suspending — proving the fix waits for it rather than racing past it.
    await proceed.open()
    await preview.value

    #expect(buffer.read(Counter.self).n == 0) // previewing the past image
    kernel.exitTimeTravel()
    #expect(buffer.read(Counter.self).n == 1) // present reflects the survived write
}

@MainActor
@Test
func exitWithoutAnActivePreviewIsHarmless() {
    let bufferBuilder = BufferBuilder()
    bufferBuilder.allocate(Counter(n: 7))
    bufferBuilder.allocate(TimeTravelState())
    let buffer = bufferBuilder.build()
    let kernel = KernelBuilder().build(buffer: buffer)

    kernel.exitTimeTravel() // no stash → no-op
    #expect(buffer.read(Counter.self).n == 7)
    #expect(buffer.read(TimeTravelState.self).previewRoot == nil)
}
#endif
