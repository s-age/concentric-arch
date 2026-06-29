import Foundation

// MARK: - Trace

/// The verb a handler resolved to — the control decision, captured as data.
package enum TraceVerb: String, Sendable {
    case next, abort, divert, fail

    init(_ verb: Verb<Any>) {
        switch verb {
        case .next: self = .next
        case .abort: self = .abort
        case .divert: self = .divert
        case .fail: self = .fail
        }
    }
}

/// One recorded symbol invocation: which node fired, how it resolved, and where
/// it sits in the call tree. The kernel-level counterpart of the buffer's domain
/// state — a bounded log the monitor reads (DEBUG only). `id` is a monotonic
/// sequence assigned on record (record order); `span`/`parent` are the tree
/// identity, independent of `id`. `parent == nil` marks a flow root.
package struct TraceEntry: Sendable, Identifiable {
    package let id: Int
    package let symbol: String
    package let verb: TraceVerb
    /// Identity of this invoke node — the span the kernel opened for it.
    package let span: UUID
    /// The enclosing invoke's span, or `nil` if this is a flow root. Lets the
    /// monitor rebuild the call tree the stack would have given for free.
    package let parent: UUID?
    /// Rendered input payload, or `nil` when capture was toggled off at record
    /// time. Output is not recorded: forward-only means a node's output is the
    /// next node's input, so it is read off the successor. See `Kernel.recordsInspection`.
    package let payload: String?
    package let timestamp: Date
}

/// Bounded ring of recent invocations, held in `kernel.buffer` so the monitor
/// observes it like any other state. `record` appends and trims to `cap`,
/// dropping the oldest — the trace is a window, not a transcript.
package struct TraceState: Sendable {
    package private(set) var entries: [TraceEntry] = []
    private var nextID = 0

    package init() {}

    package mutating func record(symbol: String, verb: TraceVerb, span: UUID, parent: UUID?, payload: String?, at timestamp: Date, cap: Int) {
        entries.append(TraceEntry(id: nextID, symbol: symbol, verb: verb, span: span, parent: parent, payload: payload, timestamp: timestamp))
        nextID += 1
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    package mutating func clear() {
        entries.removeAll()
    }
}

// MARK: - Forest

/// One node of the call forest rebuilt from the flat trace: an entry, the flow
/// root it belongs to, and the entries invoked under it. `children` is `nil` at a
/// leaf (so a hierarchical view shows no disclosure there). Built by `forest`.
package struct TraceTree: Identifiable, Sendable {
    package let entry: TraceEntry
    package let root: UUID
    package let children: [TraceTree]?
    package var id: Int { entry.id }
}

extension TraceState {
    /// Rebuild the flat `entries` into a forest of call trees via the
    /// `span`/`parent` links, so each flow is one contiguous tree rather than
    /// rows interleaved with other flows. Roots are entries with no parent, or
    /// whose parent is absent from the window (evicted, or not-yet-recorded while
    /// the flow is in-flight — post-order means the root records last); those
    /// surface as their own pseudo-roots and re-parent on a later frame once the
    /// parent appears.
    ///
    /// Order: flows newest-first by the highest id anywhere in the tree; siblings
    /// in call order (ascending id). A `visited` set guards a malformed cycle —
    /// the trace is acyclic by construction, but this reads a live partial ring.
    package var forest: [TraceTree] {
        let present = Set(entries.map(\.span))
        var childrenBySpan: [UUID: [TraceEntry]] = [:]
        var roots: [TraceEntry] = []
        for entry in entries {
            if let parent = entry.parent, present.contains(parent) {
                childrenBySpan[parent, default: []].append(entry)
            } else {
                roots.append(entry) // parent nil, evicted, or in-flight
            }
        }

        var visited: Set<UUID> = []
        func build(_ entry: TraceEntry, root: UUID) -> (node: TraceTree, maxID: Int) {
            visited.insert(entry.span)
            let kids = (childrenBySpan[entry.span] ?? [])
                .filter { !visited.contains($0.span) }
                .sorted { $0.id < $1.id }
            var built: [TraceTree] = []
            var maxID = entry.id
            for kid in kids {
                let result = build(kid, root: root)
                built.append(result.node)
                maxID = max(maxID, result.maxID)
            }
            return (TraceTree(entry: entry, root: root, children: built.isEmpty ? nil : built), maxID)
        }

        return roots
            .map { build($0, root: $0.span) }
            .sorted { $0.maxID > $1.maxID } // newest flow on top
            .map(\.node)
    }
}
