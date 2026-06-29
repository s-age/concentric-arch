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
///
/// Not `Sendable`: `image` carries erased `Any` values for live-restore. The
/// history lives only on the main actor (written by the snapshot sink, read by
/// the monitor), so it never crosses actors.
package struct BufferSnapshot: Identifiable {
    /// Monotonic sequence assigned on record (record order).
    package let id: Int
    /// Flow-root span of the command that produced this snapshot — the join key
    /// to the trace forest's `TraceTree.root`.
    package let root: UUID
    /// The captured stores rendered to text, in a stable order — the Buffer tab's
    /// read-only display.
    package let stores: [StoreDump]
    /// Erased typed copy of the same stores, for writing back into the live buffer
    /// (the "reflect to app" preview). Display uses `stores`; restore uses this.
    package let image: BufferImage
    package let timestamp: Date
}

/// Bounded ring of recent command-boundary snapshots, held in `kernel.buffer` so
/// the monitor observes it like any other state. Mirrors `TraceState`: `record`
/// appends and trims to `cap`, dropping the oldest — a window, not a transcript.
///
/// The trace gives the *control* history at invoke granularity; this gives the
/// *state* history at command granularity. They join at the flow root.
package struct BufferHistoryState {
    package private(set) var snapshots: [BufferSnapshot] = []
    private var nextID = 0

    package init() {}

    package mutating func record(root: UUID, stores: [StoreDump], image: BufferImage, at timestamp: Date, cap: Int) {
        snapshots.append(BufferSnapshot(id: nextID, root: root, stores: stores, image: image, timestamp: timestamp))
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

// MARK: - Time-travel preview

/// Live-restore preview state (DEBUG): while `previewRoot` is set, the live buffer
/// is showing a past snapshot and `stashedPresent` holds the real present so it
/// can be put back on exit. Observed by both the monitor and the main window (to
/// freeze input behind a banner). Held in `kernel.buffer` like any other state.
///
/// Not `Sendable` (`stashedPresent` is an erased `BufferImage`); it only ever
/// lives and mutates on the main actor.
package struct TimeTravelState {
    /// The flow root currently being previewed, or `nil` when live.
    package var previewRoot: UUID?
    /// The present state captured at preview entry, restored verbatim on exit.
    package var stashedPresent: BufferImage?

    package init() {}
}
