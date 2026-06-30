import Kernel
import Contract

/// The *driver* for the `Infrastructure.Library` port.
///
/// Holds the concrete store (a SwiftData-backed `any SlideshowStoring`) and binds
/// it via the `@callable`-generated `SlideshowStoringCallable.wire` — one
/// `register` per protocol method, so no operation can be left unbound.
package struct LibraryDriver {
    private let store: any SlideshowStoring

    package init(store: any SlideshowStoring) {
        self.store = store
    }

    package func wire(into builder: KernelBuilder) {
        SlideshowStoringCallable.wire(store, into: builder)
    }
}
