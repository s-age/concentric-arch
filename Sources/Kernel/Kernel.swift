import Foundation

enum KernelError: Error {
    /// No handler was wired for the given symbol id (Driver forgot to register).
    case unbound(String)
    /// A pipeline terminator (`.abort`/`.divert`) produced a value that does not
    /// match the pipe's declared `Output` — a programmer error in the rule.
    case composeTypeMismatch(expected: String, actual: String)
}

// MARK: - Builder

/// Collects the symbol → handler bindings during app wiring. Drivers register
/// into a builder; once everything is wired, `build()` freezes the bindings into
/// an immutable, `Sendable` `Kernel`.
///
/// Splitting "register" (mutable, single-threaded startup) from "call"
/// (immutable, concurrent) is what lets `Kernel` be a plain `Sendable` value
/// with no locks: registration is finished before the first call can happen.
package final class KernelBuilder {
    fileprivate var handlers: [String: @Sendable (Kernel, Any) async throws -> Verb<Any>] = [:]

    package init() {}

    /// Bind a *leaf* handler — one that fulfils the symbol on its own and makes
    /// no further kernel calls (e.g. an Infrastructure port hitting a repository).
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
        onTrace: @escaping @Sendable (_ symbol: String, _ verb: TraceVerb, _ span: UUID, _ parent: UUID?, _ at: Date) async -> Void = { _, _, _, _, _ in }
    ) -> Kernel {
        Kernel(handlers: handlers, buffer: buffer, errorSink: onError, traceSink: onTrace)
    }
}

// MARK: - Kernel

/// Dispatches `call(symbol, payload)` to the handler bound for that symbol.
///
/// The single quirk requested: you call by *symbol*, not by method —
/// `kernel.call(Infrastructure.Library.fetch, id)`. Type safety is preserved
/// end to end because `call` is generic over the symbol's `Payload`/`Output`.
package final class Kernel: Sendable {
    private let handlers: [String: @Sendable (Kernel, Any) async throws -> Verb<Any>]

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
    /// invoke's span (`nil` at a flow root).
    private let traceSink: @Sendable (_ symbol: String, _ verb: TraceVerb, _ span: UUID, _ parent: UUID?, _ at: Date) async -> Void

    #if DEBUG
    /// Ambient span of the currently-executing `invoke`, propagated down the
    /// call tree by `TaskLocal`. Each `invoke` reads it as its `parent`, opens a
    /// fresh `span`, and binds that span while its handler runs — so any nested
    /// invoke (including concurrent `async let`/TaskGroup fan-out, which inherits
    /// task-locals at creation) sees this span as its parent. A `nil` ambient
    /// means no enclosing invoke: the node is a flow root. This is how the kernel
    /// rebuilds, as data, the call tree the stack would have given for free.
    @TaskLocal static var span: UUID?
    #endif

    fileprivate init(
        handlers: [String: @Sendable (Kernel, Any) async throws -> Verb<Any>],
        buffer: Buffer,
        errorSink: @escaping @Sendable (any Error) async -> Void,
        traceSink: @escaping @Sendable (String, TraceVerb, UUID, UUID?, Date) async -> Void
    ) {
        self.handlers = handlers
        self.buffer = buffer
        self.errorSink = errorSink
        self.traceSink = traceSink
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
        let verb = try await Kernel.$span.withValue(span) {
            try await handler(self, payload)
        }
        await traceSink(id, TraceVerb(verb), span, parent, Date())
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
