import Foundation

// MARK: - Buffer snapshot

/// One named store's value rendered to text at a snapshot instant. The history
/// keeps strings, not typed values: rendering eagerly on the main actor (where
/// the buffer lives) sidesteps holding `Any` across actors and the "snapshot
/// only deep value types" invariant — a store that nests a reference type is
/// still captured correctly *as of that instant*. `name` is the state type's
/// name; `value` is its `String(describing:)`.
public struct StoreDump: Sendable, Identifiable {
    public let name: String
    public let value: String
    public var id: String { name }

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The state side of time-travel: the buffer's app-state stores rendered to text at
/// one command boundary. Tagged with `root` — the flow-root span of the command
/// that produced it — so the monitor can join a snapshot to the trace forest:
/// selecting any trace row finds its flow root, and the snapshot for that root is
/// the world *as of* that command. The kernel-level counterpart of `TraceEntry`,
/// but state instead of control.
///
/// Not `Sendable`: `image` carries erased `Any` values for live-restore. The
/// history lives only on the main actor (written by the snapshot sink, read by
/// the monitor), so it never crosses actors.
public struct BufferSnapshot: Identifiable {
    /// Monotonic sequence assigned on record (record order).
    public let id: Int
    /// Flow-root span of the command that produced this snapshot — the join key
    /// to the trace forest's `TraceTree.root`.
    public let root: UUID
    /// The captured stores rendered to text, in a stable order — the Buffer tab's
    /// read-only display.
    public let stores: [StoreDump]
    /// Erased typed copy of the same stores, for writing back into the live buffer
    /// (the "reflect to app" preview). Display uses `stores`; restore uses this.
    public let image: BufferImage
    public let timestamp: Date
}

/// Bounded ring of recent command-boundary snapshots, held in `kernel.buffer` so
/// the monitor observes it like any other state. Mirrors `TraceState`: `record`
/// appends and drops the oldest in batches, keeping the window within
/// [`cap`, `cap` × 1.25] — a window, not a transcript.
///
/// The trace gives the *control* history at invoke granularity; this gives the
/// *state* history at command granularity. They join at the flow root.
public struct BufferHistoryState {
    public private(set) var snapshots: [BufferSnapshot] = []
    private var nextID = 0

    public init() {}

    public mutating func record(root: UUID, stores: [StoreDump], image: BufferImage, at timestamp: Date, cap: Int) {
        snapshots.append(BufferSnapshot(id: nextID, root: root, stores: stores, image: image, timestamp: timestamp))
        nextID += 1
        // Same batch trim as TraceState.record: removeFirst is O(cap), so trim
        // only once the overshoot exceeds 25% of cap rather than per record.
        let overflow = snapshots.count - cap
        if overflow > cap / 4 { snapshots.removeFirst(overflow) }
    }

    /// The latest snapshot taken for a given flow root, or `nil` if the command
    /// produced none in the window (capture was off, or it was evicted). Latest
    /// because a root completes once, but a defensive `last` tolerates duplicates.
    public func snapshot(forRoot root: UUID) -> BufferSnapshot? {
        snapshots.last { $0.root == root }
    }

    public mutating func clear() {
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
public struct TimeTravelState {
    /// The flow root currently being previewed, or `nil` when live.
    public var previewRoot: UUID?
    /// The present state captured at preview entry, restored verbatim on exit.
    public var stashedPresent: BufferImage?

    public init() {}
}
