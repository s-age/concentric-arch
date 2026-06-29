import Kernel
import Contract

/// The *driver* for the `Infrastructure.Library` port.
///
/// Holds the concrete repository (a SwiftData-backed store, injected as
/// `any SlideshowStoring`) and binds it via the `@callable`-generated
/// `SlideshowStoringCallable.wire` — one `register` per protocol method, so no
/// operation can be left unbound. The *repository* naming (over a bare `store`)
/// keeps the dependency direction Driver → Contract (+ the injected store).
package struct LibraryDriver {
    private let repository: any SlideshowStoring

    package init(repository: any SlideshowStoring) {
        self.repository = repository
    }

    package func wire(into builder: KernelBuilder) {
        SlideshowStoringCallable.wire(repository, into: builder)
    }
}
