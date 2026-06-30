import Foundation

enum KernelError: Error {
    /// No handler was wired for the given symbol id (Driver forgot to register).
    case unbound(String)
    /// A pipeline terminator (`.abort`/`.divert`) produced a value that does not
    /// match the pipe's declared `Output` — a programmer error in the rule.
    case composeTypeMismatch(expected: String, actual: String)
}

// MARK: - Callable

/// The erased dispatch cell: what `Driver.register` mints when it fuses a
/// `Symbol`'s phantom types with a concrete handler, and what the kernel's
/// `handlers` table stores per symbol id.
///
/// Deliberately *not* typed in `Payload`/`Output` — those vary per symbol, so a
/// single homogeneous table can only hold the erased form (`Any` in, `Verb<Any>`
/// out). Type safety is *not* claimed here; it lives on the `Symbol` that pins
/// both ends, re-applied at the typed `call`/`register` boundary. The name states
/// the role — "a thing you can call" — not a guarantee: `invoke` is the (erased)
/// act of calling one, `call<P,O>` is the typed wrapper around an `invoke`.
package typealias Callable = @Sendable (Kernel, Any) async throws -> Verb<Any>

// MARK: - Builder

/// Collects the symbol → handler bindings during app wiring. Drivers register
/// into a builder; once everything is wired, `build()` freezes the bindings into
/// an immutable, `Sendable` `Kernel`.
///
/// Splitting "register" (mutable, single-threaded startup) from "call"
/// (immutable, concurrent) is what lets `Kernel` be a plain `Sendable` value
/// with no locks: registration is finished before the first call can happen.
package final class KernelBuilder {
    fileprivate var handlers: [String: Callable] = [:]

    package init() {}

    /// The set of symbol ids currently bound. Read after wiring (before `build`)
    /// by the wiring-exhaustiveness smoke test, which asserts it covers every
    /// declared `Symbol` id — turning a forgotten `register`/`wire` from a runtime
    /// `KernelError.unbound` on a cold path into a CI failure.
    package var boundSymbolIDs: Set<String> { Set(handlers.keys) }

    /// Bind a *leaf* handler — one that fulfils the symbol on its own and makes
    /// no further kernel calls (e.g. an Infrastructure port hitting a store).
    /// The public signature is fully typed (`(P) async throws -> O`); the unsafe
    /// `as!` that erases to `Any` is confined here, and is safe because the same
    /// `Symbol` pins both ends. The plain return is implicitly the `.next` verb.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (P) async throws -> O) {
        handlers[symbol.id] = { _, payload in .next(try await handler(payload as! P)) }
    }

    /// Bind a *composing* handler — one that receives the kernel so it can call
    /// other symbols (e.g. a Circuit handler that dispatches down to
    /// Infrastructure ports). Passing the kernel at call time, rather than wiring
    /// it in, is what breaks the build-order cycle: the handler needs the kernel
    /// only when invoked, by which point `build()` has already produced it.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (Kernel, P) async throws -> O) {
        handlers[symbol.id] = { kernel, payload in .next(try await handler(kernel, payload as! P)) }
    }

    /// Bind a *verb-returning* leaf handler — one that owns its own pipeline
    /// control: it answers `.next`/`.abort`/`.divert`/`.fail` directly instead of
    /// a bare value. In a `compose` pipe its verb drives the flow (e.g. a fetch
    /// that `.fail`s on a missing row); via `call` the verb is interpreted down
    /// to the symbol's `Output`.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (P) async throws -> Verb<O>) {
        handlers[symbol.id] = { _, payload in try await handler(payload as! P).erased() }
    }

    /// Bind a *verb-returning composing* handler — the kernel-taking counterpart
    /// of the above, for a handler that both calls other symbols and decides the
    /// verb itself.
    package func register<P, O>(_ symbol: Symbol<P, O>, _ handler: @escaping @Sendable (Kernel, P) async throws -> Verb<O>) {
        handlers[symbol.id] = { kernel, payload in try await handler(kernel, payload as! P).erased() }
    }

    /// Freeze the bindings into an immutable `Kernel`. The `Buffer` (the typed,
    /// observable state region) is built separately by `BufferBuilder` and handed
    /// in here, so the kernel owns both the behaviour side (`call`) and the state
    /// side (`buffer`).
    /// Freeze the bindings into an immutable `Kernel`. `onError` is the sink for
    /// failures of fire-and-forget commands (`Kernel.dispatch`): the App wires it
    /// to publish into the buffer's error state, so the kernel routes errors
    /// through the buffer without knowing the concrete error-state type.
    package func build(
        buffer: Buffer,
        onError: @escaping @Sendable (any Error) async -> Void = { _ in },
        onTrace: @escaping @Sendable (_ symbol: String, _ verb: TraceVerb, _ span: UUID, _ parent: UUID?, _ payload: String?, _ at: Date) async -> Void = { _, _, _, _, _, _ in },
        onSnapshot: @escaping @Sendable (_ root: UUID, _ at: Date) async -> Void = { _, _ in }
    ) -> Kernel {
        Kernel(handlers: handlers, buffer: buffer, errorSink: onError, traceSink: onTrace, snapshotSink: onSnapshot)
    }
}

// MARK: - Kernel

/// Dispatches `call(symbol, payload)` to the handler bound for that symbol.
///
/// The single quirk requested: you call by *symbol*, not by method —
/// `kernel.call(Infrastructure.Library.fetch, id)`. Type safety is preserved
/// end to end because `call` is generic over the symbol's `Payload`/`Output`.
package final class Kernel: Sendable {
    private let handlers: [String: Callable]

    /// The typed, observable state region. `Buffer` is `@MainActor` (hence
    /// implicitly `Sendable`), so a plain `Sendable` `Kernel` can hold it as a
    /// `let`. Reads/writes hop to the main actor at the call site.
    package let buffer: Buffer

    /// Serial queue for fire-and-forget commands (`dispatch`).
    private let commands = CommandBus()
    /// Where a dispatched command's failure goes — wired by App to the buffer.
    private let errorSink: @Sendable (any Error) async -> Void
    /// Where each symbol invocation is recorded (DEBUG only) — wired by App to
    /// the buffer's `TraceState`. No-op by default, so release and tests pay
    /// nothing. `span` is the node `invoke` opened; `parent` is the enclosing
    /// invoke's span (`nil` at a flow root); `payload` is the rendered input, or
    /// `nil` when capture was toggled off.
    private let traceSink: @Sendable (_ symbol: String, _ verb: TraceVerb, _ span: UUID, _ parent: UUID?, _ payload: String?, _ at: Date) async -> Void
    /// Where a flow root's resulting buffer state is captured (DEBUG only) —
    /// wired by App to render the app-state stores into the buffer's
    /// `BufferHistoryState`. Fires once per flow root (`parent == nil`), after the
    /// command has settled, tagged with the root `span` so the monitor joins each
    /// snapshot to the trace forest. No-op by default — release pays nothing.
    private let snapshotSink: @Sendable (_ root: UUID, _ at: Date) async -> Void

    #if DEBUG
    /// Ambient span of the currently-executing `invoke`, propagated down the
    /// call tree by `TaskLocal`. Each `invoke` reads it as its `parent`, opens a
    /// fresh `span`, and binds that span while its handler runs — so any nested
    /// invoke (including concurrent `async let`/TaskGroup fan-out, which inherits
    /// task-locals at creation) sees this span as its parent. A `nil` ambient
    /// means no enclosing invoke: the node is a flow root. This is how the kernel
    /// rebuilds, as data, the call tree the stack would have given for free.
    @TaskLocal static var span: UUID?

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
    #endif

    fileprivate init(
        handlers: [String: Callable],
        buffer: Buffer,
        errorSink: @escaping @Sendable (any Error) async -> Void,
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
    /// through, so the DEBUG trace hook here sees the whole graph light up,
    /// stage by stage — not just the outer boundaries. Because every node is an
    /// `invoke`, building the trace tree here (read the ambient span as parent,
    /// open a child span, bind it while the handler runs) is all it takes:
    /// `call`/`compose`/`run`/`dispatch` need no span logic of their own — they
    /// just thread the ambient span through, which is the whole "control as data"
    /// claim. The record happens after the handler returns (verb is the point of
    /// the entry), so children are recorded before their parent (post-order); the
    /// tree is rebuilt from `span`/`parent`, not from record order.
    func invoke(_ id: String, _ payload: Any) async throws -> Verb<Any> {
        guard let handler = handlers[id] else { throw KernelError.unbound(id) }
        #if DEBUG
        let parent = Kernel.span
        let span = UUID()
        // Render the input *before* the handler runs (it is the entry value, and
        // a handler may mutate a reference payload). Skipped to a bare bool load
        // unless payload capture is toggled on.
        let payloadRepr = Kernel.recordsInspection ? Kernel.describePayload(payload) : nil
        let verb = try await Kernel.$span.withValue(span) {
            try await handler(self, payload)
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
        #else
        return try await handler(self, payload)
        #endif
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
                await errorSink(error)
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

#if DEBUG
extension Kernel {
    /// Preview a past snapshot: write its `image` into the live buffer so the app
    /// renders the past. Visual only — infra (SwiftData) is untouched, so the
    /// caller must also block input (the main window disables itself behind a
    /// banner). Same chokepoint discipline as the rest of the kernel: restore is
    /// the one operation that runs *backward*, so it is fenced here as a DEBUG
    /// affordance, not a core capability.
    ///
    /// Enter-or-scrub: the *first* call stashes the real present and freezes the
    /// command bus; later calls (selection moved to another flow) just swap in the
    /// new image. Re-stashing on a scrub would capture the *displayed past* as the
    /// present, so the stash is taken once and held until `exitTimeTravel`.
    @MainActor
    package func previewTimeTravel(root: UUID, image: BufferImage) {
        if buffer.read(TimeTravelState.self).stashedPresent == nil {
            let present = buffer.capture(Set(image.keys))
            commands.suspend()
            buffer.mutate(TimeTravelState.self) { $0.stashedPresent = present }
        }
        buffer.restore(image)
        buffer.mutate(TimeTravelState.self) { $0.previewRoot = root }
    }

    /// Leave the preview: put the stashed present back and resume command draining.
    /// No-op if no preview is active.
    @MainActor
    package func exitTimeTravel() {
        guard let present = buffer.read(TimeTravelState.self).stashedPresent else { return }
        buffer.restore(present)
        commands.resumeDraining()
        buffer.mutate(TimeTravelState.self) {
            $0.previewRoot = nil
            $0.stashedPresent = nil
        }
    }
}
#endif
