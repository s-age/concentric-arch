import Foundation
import Kernel
import Contract
import Infrastructure

/// The *driver* for the `Infrastructure.Library` port.
///
/// It holds the concrete store (`SlideshowStore`) and binds each contract
/// symbol to a store call. This is the only place that knows how the
/// `Library` ports are actually fulfilled, keeping the dependency direction
/// clean: Driver → Contract (+ the concrete store), never the reverse.
///
/// The *repository* concept lives here at the Driver: it presents the
/// Infrastructure `SlideshowStore` as the collection the ports speak to — hence
/// the `repository` property name over a bare `store`.
///
/// Port references are qualified `Contract.Infrastructure.…` because this file
/// imports both the `Contract` module (whose `Infrastructure` enum holds the
/// ports) and the `Infrastructure` module (the adapter) — same bare name.
package struct LibraryDriver {
    let repository: any SlideshowStoring

    package init(repository: any SlideshowStoring) {
        self.repository = repository
    }

    /// Wire every `Infrastructure.Library` symbol into the kernel builder.
    package func wire(into builder: KernelBuilder) {
        let repository = self.repository

        builder.register(Contract.Infrastructure.Library.fetchAll) { _ in
            try await repository.fetchAll()
        }
        builder.register(Contract.Infrastructure.Library.fetch) { id in
            try await repository.fetch(id: id)
        }
        builder.register(Contract.Infrastructure.Library.save) { slideshow in
            try await repository.save(slideshow)
        }
        builder.register(Contract.Infrastructure.Library.delete) { id in
            try await repository.delete(id: id)
        }
    }
}
