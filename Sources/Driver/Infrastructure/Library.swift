import Foundation
import Kernel
import Contract
import Infrastructure

/// The *driver* for the `Infrastructure.Library` port.
///
/// It holds the concrete adapter (`SlideshowRepository`) and binds each contract
/// symbol to a repository call. This is the only place that knows how the
/// `Library` ports are actually fulfilled, keeping the dependency direction
/// clean: Driver → Contract (+ the concrete repository), never the reverse.
///
/// Port references are qualified `Contract.Infrastructure.…` because this file
/// imports both the `Contract` module (whose `Infrastructure` enum holds the
/// ports) and the `Infrastructure` module (the adapter) — same bare name.
package struct LibraryDriver {
    let repository: any SlideshowStore

    package init(repository: any SlideshowStore) {
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
