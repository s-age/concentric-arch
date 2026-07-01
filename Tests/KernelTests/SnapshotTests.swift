#if DEBUG
import Foundation
import Testing
@testable import Kernel

// MARK: - Snapshot sink synthesis (DEBUG: build(snapshotStates:))
//
// The sink is exercised directly (`kernel.snapshotSink`) rather than through a
// dispatched command: end-to-end it only fires while the process-global
// `Kernel.recordsInspection` is on, and that flag is owned by the payload-capture
// test (ComposeTests), which parallel test runs must not race. What is under
// test here is what `build` synthesizes from the declared list — capture,
// rendering, order, the restorable image — not the flow-root gating, which is
// `traced`'s pre-existing behaviour.

/// Throwaway app states — any value types work as buffer cells. Two of them, so
/// declared order is observable.
private struct Counter { var n: Int }
private struct Banner { var message: String }

@MainActor
@Test
func declaredSnapshotStatesAreRecordedIntoBufferHistoryInOrder() async throws {
    let bufferBuilder = BufferBuilder()
    bufferBuilder.allocate(Counter(n: 1))
    bufferBuilder.allocate(Banner(message: "hello"))
    bufferBuilder.allocate(BufferHistoryState())
    let buffer = bufferBuilder.build()
    let kernel = KernelBuilder().build(
        buffer: buffer,
        snapshotStates: [Counter.self, Banner.self]
    )

    let root = UUID()
    await kernel.snapshotSink(root, Date())

    let history = buffer.read(BufferHistoryState.self)
    #expect(history.snapshots.count == 1)
    let snapshot = try #require(history.snapshot(forRoot: root))
    // Dumps keep the declared order and render via `dump` (Mirror), so the
    // stored fields are visible without any conformance on the state types.
    #expect(snapshot.stores.map(\.name) == ["Counter", "Banner"])
    #expect(snapshot.stores[0].value.contains("n: 1"))
    #expect(snapshot.stores[1].value.contains("hello"))
}

@MainActor
@Test
func snapshotImageRestoresTheCapturedPast() async throws {
    let bufferBuilder = BufferBuilder()
    bufferBuilder.allocate(Counter(n: 42))
    bufferBuilder.allocate(BufferHistoryState())
    let buffer = bufferBuilder.build()
    let kernel = KernelBuilder().build(buffer: buffer, snapshotStates: [Counter.self])

    let root = UUID()
    await kernel.snapshotSink(root, Date()) // capture the past (n == 42)…

    buffer.mutate(Counter.self) { $0.n = 99 } // …the world moves on…

    let snapshot = try #require(buffer.read(BufferHistoryState.self).snapshot(forRoot: root))
    buffer.restore(snapshot.image) // …and the typed image writes it back.
    #expect(buffer.read(Counter.self).n == 42)
}

@MainActor
@Test
func emptySnapshotStatesLeaveTheSinkInert() async {
    // No states declared → the sink is a no-op: it must not touch
    // `BufferHistoryState` (which is deliberately *not* allocated here — a live
    // sink would trap on the missing store).
    let buffer = BufferBuilder().build()
    let kernel = KernelBuilder().build(buffer: buffer)

    await kernel.snapshotSink(UUID(), Date())
}
#endif
