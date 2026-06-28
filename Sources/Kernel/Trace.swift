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
    package let timestamp: Date
}

/// Bounded ring of recent invocations, held in `kernel.buffer` so the monitor
/// observes it like any other state. `record` appends and trims to `cap`,
/// dropping the oldest — the trace is a window, not a transcript.
package struct TraceState: Sendable {
    package private(set) var entries: [TraceEntry] = []
    private var nextID = 0

    package init() {}

    package mutating func record(symbol: String, verb: TraceVerb, span: UUID, parent: UUID?, at timestamp: Date, cap: Int) {
        entries.append(TraceEntry(id: nextID, symbol: symbol, verb: verb, span: span, parent: parent, timestamp: timestamp))
        nextID += 1
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    package mutating func clear() {
        entries.removeAll()
    }
}
