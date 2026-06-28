import Foundation
import Kernel
import Contract
import Infrastructure

/// The *driver* for the `Infrastructure.Config` port.
///
/// Binds the contract symbols to the concrete `ConfigStore` adapter, mirroring
/// `LibraryDriver`. Dependency direction stays Driver → Contract (+ store).
///
/// Layer-prefixed because the `Config` port exists in both layers
/// (`Infrastructure.Config` and `Circuit.Config`); their drivers would otherwise
/// collide on type name within the package.
package struct InfrastructureConfigDriver {
    let store: any ConfigStoring

    package init(store: any ConfigStoring) {
        self.store = store
    }

    /// Wire every `Infrastructure.Config` symbol into the kernel builder.
    package func wire(into builder: KernelBuilder) {
        let store = self.store

        builder.register(Contract.Infrastructure.Config.load) { _ in
            try await store.load()
        }
        builder.register(Contract.Infrastructure.Config.save) { config in
            try await store.save(config)
        }
    }
}
