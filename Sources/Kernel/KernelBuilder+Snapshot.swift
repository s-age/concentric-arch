import Foundation

// Synthesizing the snapshot sink from a declared state list — the state side of
// the DEBUG monitor's time-travel. The caller (the composition root) used to
// hand-write the whole sink: read each store, render each dump, build the typed
// image, record — four parallel lists that had to be edited together, where a
// missed entry silently dropped a store from time-travel. Declaring the list
// once in `build(snapshotStates:)` and synthesizing the sink here collapses
// those lists; the caller still owns *which* states participate (its monitor
// states — trace/history/preview — are simply not listed), the kernel absorbs
// the mechanics. The kernel stays state-agnostic: the metatypes are erased to
// `ObjectIdentifier` keys and rendered names immediately — no concrete state
// type is ever named. `Kernel.swift` carries a single unconditional `build`
// with no fences; the release build collapses the synthesis to a no-op sink.

#if DEBUG
extension KernelBuilder {
    /// Build the snapshot sink for the declared states: one `MainActor.run` hop
    /// that captures the stores as a typed `BufferImage` (for live-restore) and
    /// renders each to text (for the monitor's Buffer tab), then appends to
    /// `BufferHistoryState` — a ring capped at `cap` (`MonitorOptions.snapshotCap`),
    /// like the trace. Dumps keep the declared order, so the monitor's display
    /// is stable. A declared state whose store was never allocated traps at the
    /// first snapshot, mirroring `Buffer.read`'s missing-allocation precondition.
    static func snapshotSink(states: [Any.Type], buffer: Buffer, cap: Int) -> @Sendable (UUID, Date) async -> Void {
        if states.isEmpty { return { _, _ in } }
        // Erase the metatypes up front: keys + names are `Sendable`, the list of
        // `Any.Type` is not, and the sink must not retain app types anyway.
        let cells = states.map { (key: ObjectIdentifier($0), name: String(describing: $0)) }
        let keys = Set(cells.map(\.key))
        return { root, at in
            await MainActor.run {
                let image = buffer.capture(keys)
                let dumps = cells.map { cell -> StoreDump in
                    guard let value = image[cell.key] else {
                        preconditionFailure("Snapshot state \(cell.name) was not allocated — add its `allocate` to the BufferBuilder")
                    }
                    return StoreDump(name: cell.name, value: prettyDump(value))
                }
                buffer.mutate(BufferHistoryState.self) {
                    $0.record(root: root, stores: dumps, image: image, at: at, cap: cap)
                }
            }
        }
    }
}

/// Multi-line, indented reflection of a store's value for the monitor's Buffer
/// tab. `dump` walks the value with `Mirror`, so it needs no `Codable`/
/// `CustomString` conformance — it pretty-prints any app state as-is, which is
/// why the snapshot keeps strings (rendered here) rather than typed values.
/// Uncapped, unlike `describePayload`: the Buffer tab shows whole stores.
private func prettyDump(_ value: Any) -> String {
    var text = ""
    dump(value, to: &text)
    return text
}
#else
extension KernelBuilder {
    /// Release: snapshots don't exist — the sink is a no-op whatever the list.
    static func snapshotSink(states: [Any.Type], buffer: Buffer, cap: Int) -> @Sendable (UUID, Date) async -> Void {
        { _, _ in }
    }
}
#endif
