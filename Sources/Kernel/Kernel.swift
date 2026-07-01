import Foundation

enum KernelError: Error {
    /// No handler was wired for the given symbol id (Driver forgot to register).
    case unbound(String)
    /// A pipeline terminator (`.abort`/`.divert`) produced a value that does not
    /// match the pipe's declared `Output` — a programmer error in the rule.
    case composeTypeMismatch(expected: String, actual: String)
}

// MARK: - ErasedHandler

/// The erased dispatch cell: what `Driver.register` mints when it fuses a
/// `Symbol`'s phantom types with a concrete handler, and what the kernel's
/// `handlers` table stores per symbol id.
///
/// Deliberately *not* typed in `Payload`/`Output` — those vary per symbol, so a
/// single homogeneous table can only hold the erased form (`Any` in, `Verb<Any>`
/// out). Type safety is *not* claimed here; it lives on the `Symbol` that pins
/// both ends, re-applied at the typed `call`/`register` boundary. The name states
/// the role — an *erased* handler — not a guarantee: `invoke` is the (erased) act
/// of calling one, `call<P,O>` is the typed wrapper around an `invoke`.
///
/// (The typed, human-readable index of every callable endpoint is `Callable` in
/// the `Contract` module — the dispatch-key namespace. This is the runtime cell
/// those keys resolve to.)
package typealias ErasedHandler = @Sendable (Kernel, Any) async throws -> Verb<Any>

// MARK: - Builder

/// Collects the symbol → handler bindings during app wiring. Drivers register
/// into a builder; once everything is wired, `build()` freezes the bindings into
/// an immutable, `Sendable` `Kernel`.
///
/// Splitting "register" (mutable, single-threaded startup) from "call"
/// (immutable, concurrent) is what lets `Kernel` be a plain `Sendable` value
/// with no locks: registration is finished before the first call can happen.
package final class KernelBuilder {
    fileprivate var handlers: [String: ErasedHandler] = [:]

    package init() {}

    /// The set of symbol ids currently bound. Read after wiring (before `build`)
    /// by the wiring-exhaustiveness smoke test, which asserts it covers every
    /// declared `Symbol` id — turning a forgotten `register`/`wire` from a runtime
    /// `KernelError.unbound` on a cold path into a CI failure.
    package var boundSymbolIDs: Set<String> { Set(handlers.keys) }

    /// The single write point of the handler table — every `register` overload
    /// funnels through here. Two bindings for one symbol id would silently
    /// last-write-win, and which handler answers a symbol is the runtime half of
    /// the architecture's guarantee, so a duplicate traps immediately at the
    /// second `register` (where the stack names the offender) rather than
    /// surfacing as the wrong device answering on some cold path. Build-then-
    /// freeze makes this a `precondition`, not a `throw`: wiring is
    /// single-threaded startup code, so a duplicate is always a programming
    /// error, never an input.
    private func bind(_ id: String, _ handler: @escaping ErasedHandler) {
        precondition(handlers[id] == nil, "Symbol '\(id)' is already bound — duplicate register")
        handlers[id] = handler
    }

    /// Bind a *leaf* handler — one that fulfils the symbol on its own and makes
    /// no further kernel calls (e.g. an Infrastructure port hitting a store).
    /// The public signature is fully typed (`(P) async throws -> O`); the unsafe
    /// `as!` that erases to `Any` is confined here, and is safe because the same
    /// `Symbol` pins both ends. The plain return is implicitly the `.next` verb.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (P) async throws -> O) {
        bind(symbol.id) { _, payload in .next(try await handler(payload as! P)) }
    }

    /// Bind a *composing* handler — one that receives the kernel so it can call
    /// other symbols (e.g. a Circuit handler that dispatches down to
    /// Infrastructure ports). Passing the kernel at call time, rather than wiring
    /// it in, is what breaks the build-order cycle: the handler needs the kernel
    /// only when invoked, by which point `build()` has already produced it.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (Kernel, P) async throws -> O) {
        bind(symbol.id) { kernel, payload in .next(try await handler(kernel, payload as! P)) }
    }

    /// Bind a *verb-returning* leaf handler — one that owns its own pipeline
    /// control: it answers `.next`/`.abort`/`.divert`/`.fail` directly instead of
    /// a bare value. In a `compose` pipe its verb drives the flow (e.g. a fetch
    /// that `.fail`s on a missing row); via `call` the verb is interpreted down
    /// to the symbol's `Output`.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (P) async throws -> Verb<O>) {
        bind(symbol.id) { _, payload in try await handler(payload as! P).erased() }
    }

    /// Bind a *verb-returning composing* handler — the kernel-taking counterpart
    /// of the above, for a handler that both calls other symbols and decides the
    /// verb itself.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (Kernel, P) async throws -> Verb<O>) {
        bind(symbol.id) { kernel, payload in try await handler(kernel, payload as! P).erased() }
    }

    /// Freeze the bindings into an immutable `Kernel`. The `Buffer` (the typed,
    /// observable state region) is built separately by `BufferBuilder` and handed
    /// in here, so the kernel owns both the behaviour side (`call`) and the state
    /// side (`buffer`). Both sinks default to framework implementations that
    /// target the kernel's own buffer states — the injection points remain, so
    /// the kernel still never names an *app* state type:
    /// - `onError` is the sink for failures of fire-and-forget commands
    ///   (`Kernel.dispatch`). `symbol` is the id of the dispatched command that
    ///   failed — the caller already holds it, so it travels alongside the error
    ///   rather than being dropped. Omitted, failures render into
    ///   `KernelErrorState` (release too); inject to publish into a custom
    ///   error state instead.
    /// - `onTrace` is the DEBUG trace sink. Omitted, every invocation records
    ///   into `TraceState`, capped at `monitor.traceCap`; inject to record
    ///   elsewhere (an injected sink owns its own cap).
    /// `monitor` carries the DEBUG tuning knobs (ring caps today) as one value,
    /// ignored in release. `snapshotStates` is the state side of time-travel,
    /// declared instead of wired: the buffer stores to capture at each command
    /// boundary (rendered for display + typed image for live-restore, recorded
    /// into `BufferHistoryState`). The caller still owns *which* states
    /// participate; the kernel absorbs the mechanics — see
    /// `KernelBuilder+Snapshot`. The kernel stays state-agnostic: the list is
    /// erased to keys and names, never concrete types. Empty (the default)
    /// means no snapshots; in release the sink is a no-op regardless.
    package func build(
        buffer: Buffer,
        onError: (@Sendable (_ error: any Error, _ symbol: String) async -> Void)? = nil,
        onTrace: (@Sendable (_ symbol: String, _ verb: TraceVerb, _ span: UUID, _ parent: UUID?, _ payload: String?, _ at: Date) async -> Void)? = nil,
        monitor: MonitorOptions = MonitorOptions(),
        snapshotStates: [Any.Type] = []
    ) -> Kernel {
        Kernel(
            handlers: handlers,
            buffer: buffer,
            errorSink: onError ?? Self.defaultErrorSink(buffer: buffer),
            traceSink: onTrace ?? Self.defaultTraceSink(buffer: buffer, cap: monitor.traceCap),
            snapshotSink: Self.snapshotSink(states: snapshotStates, buffer: buffer, cap: monitor.snapshotCap)
        )
    }
}

// MARK: - Kernel

/// Dispatches `call(symbol, payload)` to the handler bound for that symbol.
///
/// The single quirk requested: you call by *symbol*, not by method —
/// `kernel.call(Infrastructure.Library.fetch, id)`. Type safety is preserved
/// end to end because `call` is generic over the symbol's `Payload`/`Output`.
package final class Kernel: Sendable {
    private let handlers: [String: ErasedHandler]

    /// The typed, observable state region. `Buffer` is `@MainActor` (hence
    /// implicitly `Sendable`), so a plain `Sendable` `Kernel` can hold it as a
    /// `let`. Reads/writes hop to the main actor at the call site.
    package let buffer: Buffer

    /// Serial queue for fire-and-forget commands (`dispatch`). Internal (not
    /// `private`) because the DEBUG time-travel extension suspends/resumes it.
    let commands = CommandBus()
    /// Where a dispatched command's failure goes — wired by App to the buffer.
    private let errorSink: @Sendable (any Error, String) async -> Void
    /// Where each symbol invocation is recorded (DEBUG only) — wired by App to
    /// the buffer's `TraceState`. No-op by default, so release and tests pay
    /// nothing. `span` is the node `invoke` opened; `parent` is the enclosing
    /// invoke's span (`nil` at a flow root); `payload` is the rendered input, or
    /// `nil` when capture was toggled off. Stored here (not in the DEBUG
    /// extension — extensions can't hold stored properties), read by `traced`
    /// in `Kernel+Trace`; a no-op closure in release, so left unfenced — fencing
    /// it would fork `build()`'s signature across build configurations and
    /// contaminate the App call site.
    let traceSink: @Sendable (_ symbol: String, _ verb: TraceVerb, _ span: UUID, _ parent: UUID?, _ payload: String?, _ at: Date) async -> Void
    /// Where a flow root's resulting buffer state is captured (DEBUG only) —
    /// synthesized by `build(snapshotStates:)` to render the declared stores
    /// into the buffer's `BufferHistoryState`. Fires once per flow root
    /// (`parent == nil`), after the command has settled, tagged with the root
    /// `span` so the monitor joins each snapshot to the trace forest. No-op when
    /// no states are declared — and always in release, so release pays nothing.
    /// Unfenced for the same reason as `traceSink`.
    let snapshotSink: @Sendable (_ root: UUID, _ at: Date) async -> Void

    fileprivate init(
        handlers: [String: ErasedHandler],
        buffer: Buffer,
        errorSink: @escaping @Sendable (any Error, String) async -> Void,
        traceSink: @escaping @Sendable (String, TraceVerb, UUID, UUID?, String?, Date) async -> Void,
        snapshotSink: @escaping @Sendable (UUID, Date) async -> Void
    ) {
        self.handlers = handlers
        self.buffer = buffer
        self.errorSink = errorSink
        self.traceSink = traceSink
        self.snapshotSink = snapshotSink
    }

    /// Run the bound handler for `id` and hand back its raw verb. The pipeline
    /// runner (`compose`) consumes this directly so a handler's own
    /// `.next`/`.abort`/`.divert`/`.fail` drives the flow.
    ///
    /// This is the single chokepoint every `call`/`dispatch`/pipe stage funnels
    /// through, so wrapping the handler in `traced` (Kernel+Trace) is all the
    /// DEBUG monitor needs to see the whole graph light up, stage by stage — not
    /// just the outer boundaries. In release `traced` is an inlined passthrough,
    /// so this one body serves both configurations.
    func invoke(_ id: String, _ payload: Any) async throws -> Verb<Any> {
        guard let handler = handlers[id] else { throw KernelError.unbound(id) }
        return try await traced(id, payload) { try await handler(self, payload) }
    }

    /// Call one symbol and get its typed `Output`. A single call is just a
    /// one-stage pipeline: invoke the handler, then interpret the verb down to `O`.
    package func call<P, O>(_ symbol: Symbol<P, O>, _ payload: P) async throws -> O {
        let verb = try await invoke(symbol.id, payload)
        return try await interpret(verb, as: O.self)
    }

    /// Fire-and-forget command: enqueue on the serial bus and return immediately —
    /// no `await`, no return value, no `throws`. The command runs in submission
    /// order; if it fails, the error goes to the sink (the buffer's error state).
    /// For Void commands whose result is published through the buffer; queries
    /// that need a value keep `call`.
    package func dispatch<P: Sendable, O>(_ symbol: Symbol<P, O>, _ payload: P) {
        commands.enqueue { [self] in
            do {
                _ = try await call(symbol, payload)
            } catch {
                await errorSink(error, symbol.id)
            }
        }
    }
}

extension Kernel {
    /// Sugar for the many no-payload endpoints: `kernel.call(Symbol)`.
    package func call<O>(_ symbol: Symbol<Void, O>) async throws -> O {
        try await call(symbol, ())
    }
}
