import Foundation

// Reconstructing the call tree as data — the trace side of the DEBUG monitor.
// `invoke` stays the single chokepoint; `traced` is the hook it funnels every
// invocation through. The DEBUG build implements the span/trace/snapshot
// machinery here; the release build collapses the hook to a plain passthrough,
// so `Kernel.swift` carries a single unconditional `invoke` with no fences.

#if DEBUG
extension Kernel {
    /// Ambient span of the currently-executing `invoke`, propagated down the
    /// call tree by `TaskLocal`. Each `invoke` reads it as its `parent`, opens a
    /// fresh `span`, and binds that span while its handler runs — so any nested
    /// invoke (including concurrent `async let`/TaskGroup fan-out, which inherits
    /// task-locals at creation) sees this span as its parent. A `nil` ambient
    /// means no enclosing invoke: the node is a flow root. This is how the kernel
    /// rebuilds, as data, the call tree the stack would have given for free.
    @TaskLocal static var span: UUID?

    /// The trace hook `invoke` wraps every handler in. Because every node is an
    /// `invoke`, building the trace tree here (read the ambient span as parent,
    /// open a child span, bind it while the handler runs) is all it takes:
    /// `call`/`compose`/`run`/`dispatch` need no span logic of their own — they
    /// just thread the ambient span through, which is the whole "control as data"
    /// claim. The record happens after the handler returns (verb is the point of
    /// the entry), so children are recorded before their parent (post-order); the
    /// tree is rebuilt from `span`/`parent`, not from record order.
    func traced(_ id: String, _ payload: Any,
                _ body: () async throws -> Verb<Any>) async throws -> Verb<Any> {
        let parent = Kernel.span
        let span = UUID()
        // Render the input *before* the handler runs (it is the entry value, and
        // a handler may mutate a reference payload). Skipped to a bare bool load
        // unless payload capture is toggled on.
        let payloadRepr = Kernel.recordsInspection ? Kernel.describePayload(payload) : nil
        let verb = try await Kernel.$span.withValue(span) {
            try await body()
        }
        await traceSink(id, TraceVerb(verb), span, parent, payloadRepr, Date())
        // A flow root (`parent == nil`) completing is a command boundary: the
        // handler has returned, so the buffer has settled. Capture the resulting
        // state here, tagged with this root's span — the same chokepoint, no
        // snapshot logic in `call`/`dispatch`. Children (which have a parent) skip
        // this; we snapshot at command granularity, not per invoke.
        if parent == nil && Kernel.recordsInspection {
            await snapshotSink(span, Date())
        }
        return verb
    }
}
#else
extension Kernel {
    /// Release: no spans, no records — the hook is the handler call itself.
    @inline(__always)
    func traced(_ id: String, _ payload: Any,
                _ body: () async throws -> Verb<Any>) async throws -> Verb<Any> {
        try await body()
    }
}
#endif
