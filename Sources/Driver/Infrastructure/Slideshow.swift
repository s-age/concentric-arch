import Kernel
import Contract

/// The *driver* for the `Infrastructure.Slideshow` port — per-slideshow CRUD.
///
/// Layer-prefixed (`Infrastructure…`) to avoid colliding with the Circuit
/// slideshow driver, since the `Slideshow` name is shared across both layers —
/// the same convention as the two `Config` drivers.
///
/// Holds the concrete store (a SwiftData-backed `any SlideshowStoring`) and binds
/// it via the `@callable`-generated `Callable.Infrastructure.Slideshow.wire`.
package struct InfrastructureSlideshowDriver {
    private let store: any SlideshowStoring

    package init(store: any SlideshowStoring) {
        self.store = store
    }

    package func wire(into builder: KernelBuilder) {
        Callable.Infrastructure.Slideshow.wire(store, into: builder)
    }
}
