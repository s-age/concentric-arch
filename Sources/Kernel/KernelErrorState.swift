import Foundation

// The framework-provided default error channel — the state side of `dispatch`'s
// error sink. A failure inside a fire-and-forget command has no return path to
// `catch`; unless the app injects its own `onError` at `build`, the default
// sink renders the failure here and the view layer observes it like any other
// state. `BufferBuilder.build()` allocates the store unconditionally (errors
// are a release feature, unlike the DEBUG monitor states), so the default sink
// can never hit a missing allocation.

/// Global error channel in the buffer, owned by the kernel.
///
/// The default target of `Kernel.dispatch`'s error sink: one optional message,
/// written as `"symbol: description"`, cleared by whoever displays it. An app
/// that wants a richer error shape keeps the classic route — allocate its own
/// state and inject `onError` at `build`; this store then just sits unused.
public struct KernelErrorState: Sendable {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }
}

extension KernelBuilder {
    /// The error sink `build` falls back to when the caller injects none:
    /// render the failed command's symbol id and error description into
    /// `KernelErrorState`. Active in release too — `dispatch` swallows the
    /// error either way, and a silently dropped failure is the worse default.
    static func defaultErrorSink(buffer: Buffer) -> @Sendable (any Error, String) async -> Void {
        { error, symbol in
            await buffer.mutate(KernelErrorState.self) {
                $0.message = "\(symbol): \(error.localizedDescription)"
            }
        }
    }
}
