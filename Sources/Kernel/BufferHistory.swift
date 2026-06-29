import Foundation

// MARK: - Buffer snapshot

/// One named store's value rendered to text at a snapshot instant. The history
/// keeps strings, not typed values: rendering eagerly on the main actor (where
/// the buffer lives) sidesteps holding `Any` across actors and the "snapshot
/// only deep value types" invariant — a store that nests a reference type is
/// still captured correctly *as of that instant*. `name` is the state type's
/// name; `value` is its `String(describing:)`.
package struct StoreDump: Sendable, Identifiable {
    package let name: String
    package let value: String
    package var id: String { name }

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The state side of time-travel: the buffer's domain stores rendered to text at
/// one command boundary. Tagged with `root` — the flow-root span of the command
/// that produced it — so the monitor can join a snapshot to the trace forest:
/// selecting any trace row finds its flow root, and the snapshot for that root is
/// the world *as of* that command. The kernel-level counterpart of `TraceEntry`,
/// but state instead of control.
package struct BufferSnapshot: Sendable, Identifiable {
    /// Monotonic sequence assigned on record (record order).
    package let id: Int
    /// Flow-root span of the command that produced this snapshot — the join key
    /// to the trace forest's `TraceTree.root`.
    package let root: UUID
    /// The captured stores, in a stable order fixed by the snapshot sink.
    package let stores: [StoreDump]
    package let timestamp: Date
}

/// Bounded ring of recent command-boundary snapshots, held in `kernel.buffer` so
/// the monitor observes it like any other state. Mirrors `TraceState`: `record`
/// appends and trims to `cap`, dropping the oldest — a window, not a transcript.
///
/// The trace gives the *control* history at invoke granularity; this gives the
/// *state* history at command granularity. They join at the flow root.
package struct BufferHistoryState: Sendable {
    package private(set) var snapshots: [BufferSnapshot] = []
    private var nextID = 0

    package init() {}

    package mutating func record(root: UUID, stores: [StoreDump], at timestamp: Date, cap: Int) {
        snapshots.append(BufferSnapshot(id: nextID, root: root, stores: stores, timestamp: timestamp))
        nextID += 1
        if snapshots.count > cap { snapshots.removeFirst(snapshots.count - cap) }
    }

    /// The latest snapshot taken for a given flow root, or `nil` if the command
    /// produced none in the window (capture was off, or it was evicted). Latest
    /// because a root completes once, but a defensive `last` tolerates duplicates.
    package func snapshot(forRoot root: UUID) -> BufferSnapshot? {
        snapshots.last { $0.root == root }
    }

    package mutating func clear() {
        snapshots.removeAll()
    }
}
