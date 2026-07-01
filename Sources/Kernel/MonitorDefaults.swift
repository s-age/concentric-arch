import Foundation

// Framework-provided defaults for the DEBUG monitor's boot ritual. Every app
// used to hand-write the same three `allocate` lines (the kernel-owned monitor
// states — forgetting one was a `preconditionFailure` at first access) and the
// same `onTrace` body (append to `TraceState`, the only app-specific part being
// the cap). `BufferBuilder.build()` and `KernelBuilder.build()` now absorb
// both; the injection points stay — a custom `onTrace` still overrides — so
// "sinks are injected, kernel stays state-agnostic" holds: these defaults only
// name the kernel's *own* monitor states, never an app type.

/// Tuning knobs for the DEBUG monitor, passed at `KernelBuilder.build`.
/// One value instead of one parameter per knob, so future settings extend this
/// struct without touching `build`'s signature. Ignored entirely in release
/// (the sinks it configures are no-ops there); unfenced for the same reason as
/// the sinks — fencing would fork `build()`'s signature across configurations.
package struct MonitorOptions: Sendable {
    /// Ring size of `TraceState` when the default trace sink is used
    /// (an injected `onTrace` owns its own cap).
    package var traceCap: Int
    /// Ring size of `BufferHistoryState` used by the synthesized snapshot sink.
    package var snapshotCap: Int

    package init(traceCap: Int = 300, snapshotCap: Int = 100) {
        self.traceCap = traceCap
        self.snapshotCap = snapshotCap
    }
}

#if DEBUG
extension BufferBuilder {
    /// Seed the kernel-owned monitor states (trace ring, snapshot history,
    /// time-travel preview) — called by `build()`, so every DEBUG buffer simply
    /// has them and the "forgot to allocate" failure class cannot occur.
    /// `allocateIfAbsent` keeps an explicit caller allocation (e.g. a pre-seeded
    /// state in a test) authoritative.
    func allocateMonitorStates() {
        allocateIfAbsent(TraceState())
        allocateIfAbsent(BufferHistoryState())
        allocateIfAbsent(TimeTravelState())
    }
}

extension KernelBuilder {
    /// The trace sink `build` falls back to when the caller injects none:
    /// append every invocation to `TraceState`, capped at `cap`. Safe without
    /// preconditions because `BufferBuilder.build()` guarantees the store.
    static func defaultTraceSink(buffer: Buffer, cap: Int) -> @Sendable (String, TraceVerb, UUID, UUID?, String?, Date) async -> Void {
        { symbol, verb, span, parent, payload, at in
            await buffer.mutate(TraceState.self) {
                $0.record(symbol: symbol, verb: verb, span: span, parent: parent, payload: payload, at: at, cap: cap)
            }
        }
    }
}
#else
extension BufferBuilder {
    /// Release: the monitor doesn't exist — nothing to seed.
    func allocateMonitorStates() {}
}

extension KernelBuilder {
    /// Release: `traced` is a passthrough that never calls the sink — a no-op
    /// keeps `build` unfenced.
    static func defaultTraceSink(buffer: Buffer, cap: Int) -> @Sendable (String, TraceVerb, UUID, UUID?, String?, Date) async -> Void {
        { _, _, _, _, _, _ in }
    }
}
#endif
