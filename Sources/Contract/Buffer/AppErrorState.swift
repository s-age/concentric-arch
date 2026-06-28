import Foundation

/// Global error channel in the buffer.
///
/// The unidirectional counterpart to the old per-view-model `errorMessage`: a
/// failure inside a kernel-dispatched command has no return path to `catch`, so
/// the kernel's error sink writes it here and Presentation observes it (a single
/// banner at the top of the window — see `ContentView`). Local, view-confined
/// validation can still live in a view model; this is for failures that escape a
/// pipeline.
package struct AppErrorState: Sendable {
    package var message: String?

    package init(message: String? = nil) {
        self.message = message
    }
}
