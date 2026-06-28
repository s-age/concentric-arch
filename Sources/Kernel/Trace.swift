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

/// One recorded symbol invocation: which node fired and how it resolved. The
/// kernel-level counterpart of the buffer's domain state — a bounded log the
/// monitor reads (DEBUG only). `id` is a monotonic sequence assigned on record.
package struct TraceEntry: Sendable, Identifiable {
    package let id: Int
    package let symbol: String
    package let verb: TraceVerb
    package let timestamp: Date
}

/// Bounded ring of recent invocations, held in `kernel.buffer` so the monitor
/// observes it like any other state. `record` appends and trims to `cap`,
/// dropping the oldest — the trace is a window, not a transcript.
package struct TraceState: Sendable {
    package private(set) var entries: [TraceEntry] = []
    private var nextID = 0

    package init() {}

    package mutating func record(symbol: String, verb: TraceVerb, at timestamp: Date, cap: Int) {
        entries.append(TraceEntry(id: nextID, symbol: symbol, verb: verb, timestamp: timestamp))
        nextID += 1
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    package mutating func clear() {
        entries.removeAll()
    }
}
