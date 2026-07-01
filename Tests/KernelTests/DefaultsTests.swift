import Foundation
import Testing
@testable import Kernel

// MARK: - Framework-provided boot defaults
//
// The boot ritual every app used to hand-write — monitor-state allocation, the
// trace sink body, the error state + sink — is now seeded by
// `BufferBuilder.build()` / defaulted by `KernelBuilder.build()`. These tests
// pin the provisioning (stores exist, caller allocations win) and the default
// sinks (errors land in `KernelErrorState`, traces in `TraceState`, caps come
// from `MonitorOptions`), plus that injection still overrides.

/// A throwaway app state — any value type works as a buffer cell.
private struct Counter { var n: Int }

private struct Boom: Error {}
private let boom = Symbol<Int, Void>("test.defaults.boom")
private let ping = Symbol<Void, Void>("test.defaults.ping")

/// Records which stages actually executed (same idiom as ComposeTests).
private actor Probe {
    private(set) var hits: [String] = []
    func hit(_ name: String) { hits.append(name) }
}

/// Polls until `condition` holds — how a test observes a fire-and-forget
/// dispatch settling without a return path to await.
private func until(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never became true")
}

// MARK: - Buffer provisioning

@MainActor
@Test
func buildSeedsKernelErrorStateWithoutAnyAllocateCall() {
    let buffer = BufferBuilder().build()
    #expect(buffer.read(KernelErrorState.self).message == nil)
}

#if DEBUG
@MainActor
@Test
func buildSeedsTheMonitorStatesWithoutAnyAllocateCall() {
    let buffer = BufferBuilder().build()
    #expect(buffer.read(TraceState.self).entries.isEmpty)
    #expect(buffer.read(BufferHistoryState.self).snapshots.isEmpty)
    #expect(buffer.read(TimeTravelState.self).previewRoot == nil)
}
#endif

@MainActor
@Test
func explicitAllocationIsNotClobberedByTheDefaultSeeding() {
    let bufferBuilder = BufferBuilder()
    bufferBuilder.allocate(KernelErrorState(message: "seeded"))
    let buffer = bufferBuilder.build()
    #expect(buffer.read(KernelErrorState.self).message == "seeded")
}

// MARK: - Default error sink

@Test
func defaultErrorSinkRendersDispatchFailureIntoKernelErrorState() async throws {
    let probe = Probe()
    let (kernel, buffer) = await MainActor.run { () -> (Kernel, Buffer) in
        let buffer = BufferBuilder().build()
        let builder = KernelBuilder()
        builder.register(boom) { _ -> Verb<Void> in .fail(Boom()) }
        builder.register(ping) { await probe.hit("ping") }
        return (builder.build(buffer: buffer), buffer)
    }

    kernel.dispatch(boom, 1)
    kernel.dispatch(ping, ()) // serial bus: once this ran, boom has settled
    try await until { await probe.hits.count == 1 }

    let message = await MainActor.run { buffer.read(KernelErrorState.self).message }
    #expect(message?.contains("test.defaults.boom") == true)
}

@Test
func injectedErrorSinkOverridesTheDefault() async throws {
    let probe = Probe()
    let (kernel, buffer) = await MainActor.run { () -> (Kernel, Buffer) in
        let buffer = BufferBuilder().build()
        let builder = KernelBuilder()
        builder.register(boom) { _ -> Verb<Void> in .fail(Boom()) }
        let kernel = builder.build(buffer: buffer) { error, symbol in
            await probe.hit("err:\(error):\(symbol)")
        }
        return (kernel, buffer)
    }

    kernel.dispatch(boom, 1)
    try await until { await probe.hits.count == 1 }

    #expect(await probe.hits.first == "err:Boom():test.defaults.boom")
    // The default target stays untouched — the injected sink replaced it.
    let message = await MainActor.run { buffer.read(KernelErrorState.self).message }
    #expect(message == nil)
}

// MARK: - Default trace sink (DEBUG: traced never fires in release)

#if DEBUG
@Test
func defaultTraceSinkRecordsEveryInvocationIntoTraceState() async throws {
    let (kernel, buffer) = await MainActor.run { () -> (Kernel, Buffer) in
        let buffer = BufferBuilder().build()
        let builder = KernelBuilder()
        builder.register(ping) {}
        return (builder.build(buffer: buffer), buffer)
    }

    try await kernel.call(ping)

    // `traced` awaits the sink before returning, so the record is committed.
    let entries = await MainActor.run { buffer.read(TraceState.self).entries }
    #expect(entries.map(\.symbol) == ["test.defaults.ping"])
    #expect(entries.first?.verb == .next)
}

@Test
func monitorOptionsTraceCapBoundsTheDefaultSinkRing() async throws {
    let (kernel, buffer) = await MainActor.run { () -> (Kernel, Buffer) in
        let buffer = BufferBuilder().build()
        let builder = KernelBuilder()
        builder.register(ping) {}
        return (builder.build(buffer: buffer, monitor: MonitorOptions(traceCap: 4)), buffer)
    }

    for _ in 0..<10 { try await kernel.call(ping) }

    // The ring trims in batches: the window stays within [cap, cap × 1.25].
    let count = await MainActor.run { buffer.read(TraceState.self).entries.count }
    #expect(count >= 4 && count <= 5)
}

@Test
func monitorOptionsSnapshotCapBoundsTheSynthesizedSinkRing() async throws {
    let (kernel, buffer) = await MainActor.run { () -> (Kernel, Buffer) in
        let bufferBuilder = BufferBuilder()
        bufferBuilder.allocate(Counter(n: 0))
        let buffer = bufferBuilder.build()
        let kernel = KernelBuilder().build(
            buffer: buffer,
            monitor: MonitorOptions(snapshotCap: 2),
            snapshotStates: [Counter.self]
        )
        return (kernel, buffer)
    }

    for _ in 0..<5 { await kernel.snapshotSink(UUID(), Date()) }

    // cap / 4 == 0, so any overflow trims immediately — exactly `cap` survive.
    let count = await MainActor.run { buffer.read(BufferHistoryState.self).snapshots.count }
    #expect(count == 2)
}
#endif
