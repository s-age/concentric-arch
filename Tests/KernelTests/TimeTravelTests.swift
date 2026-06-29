#if DEBUG
import Foundation
import Testing
@testable import Kernel

// MARK: - Time-travel preview (DEBUG: enter/exit round-trip)

/// A throwaway app state — any value type works as a buffer cell.
private struct Counter { var n: Int }

@MainActor
@Test
func timeTravelScrubsBetweenPastsThenRestoresPresentOnExit() {
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
    kernel.previewTimeTravel(root: rootA, image: imageA)
    #expect(buffer.read(Counter.self).n == 1)
    #expect(buffer.read(TimeTravelState.self).previewRoot == rootA)

    // Selecting another flow scrubs to B — without re-stashing, so exit must still
    // land on the original present (9), not on a previewed past (1).
    kernel.previewTimeTravel(root: rootB, image: imageB)
    #expect(buffer.read(Counter.self).n == 2)
    #expect(buffer.read(TimeTravelState.self).previewRoot == rootB)

    kernel.exitTimeTravel()
    #expect(buffer.read(Counter.self).n == 9)
    #expect(buffer.read(TimeTravelState.self).previewRoot == nil)
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
