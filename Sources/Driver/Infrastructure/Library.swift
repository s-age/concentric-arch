import Kernel
import Contract

/// The *driver* for the `Infrastructure.Library` port — the catalog read.
///
/// Layer-prefixed because `Library` now names a device in both the Circuit and
/// Infrastructure layers (same convention as `Config` / `Slideshow`).
///
/// Holds the concrete store (a SwiftData-backed `any LibraryStoring`) and binds it
/// via the `@callable`-generated `Callable.Infrastructure.Library.wire` — one
/// `register` per protocol method, so no operation can be left unbound.
package struct InfrastructureLibraryDriver {
    private let store: any LibraryStoring

    package init(store: any LibraryStoring) {
        self.store = store
    }

    package func wire(into builder: KernelBuilder) {
        Callable.Infrastructure.Library.wire(store, into: builder)
    }
}
