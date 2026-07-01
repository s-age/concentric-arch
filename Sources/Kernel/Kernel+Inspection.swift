#if DEBUG
import Foundation

// Rendering live values into something human-readable — the inspection side of
// the DEBUG monitor. `traced` (Kernel+Trace) reads both members per invoke;
// the monitor's toggle and detail pane bind to them from Presentation.

extension Kernel {
    /// Single runtime toggle for the monitor's two captures: each invoke's input
    /// payload (per invoke) and the buffer's app state at each command boundary
    /// (per flow root, the state side of time-travel). One switch because the
    /// monitor inspects them together — there is no reason to want one without the
    /// other. Off by default, so the common path pays only a bool load; turning it
    /// on opts into a synchronous `String(describing:)` per invoke plus one per
    /// app-state store per flow root. A process-global flag read on the hot path —
    /// deliberately *not* in the `@MainActor` buffer, which would hop every invoke
    /// onto the main actor and serialize them. The monitor's toggle binds straight
    /// to it. The race on a lone debug bool is benign (a flip may catch one
    /// in-flight invoke either way), so `nonisolated(unsafe)` rather than an atomic.
    nonisolated(unsafe) package static var recordsInspection = false

    /// Best-effort, length-capped *pretty* rendering of an invoke's input. Built
    /// eagerly at the call site because `payload` is `Any` — neither `Sendable`
    /// nor stable, so it can't be stashed and pretty-printed later (a reference
    /// type could mutate, or refuse to cross actors); the detail pane only ever
    /// sees this string, never the live value. `dump` walks the value with
    /// `Mirror`, so any payload type pretty-prints (indented, multi-line) with no
    /// conformance — matching the Buffer tab. The cap bounds what we *store*, not
    /// what rendering costs to *build* — a huge payload is heavy regardless;
    /// `recordsInspection` is the cost guard, the cap is hygiene.
    package static func describePayload(_ payload: Any, cap: Int = 1024) -> String {
        var full = ""
        dump(payload, to: &full)
        // `dump` ends every value with a newline; drop it so a scalar payload
        // ("- 42\n") doesn't carry a trailing blank line into the trace.
        if full.hasSuffix("\n") { full.removeLast() }
        let head = full.prefix(cap)
        return full.dropFirst(cap).isEmpty ? String(head) : String(head) + "…"
    }
}
#endif
