import Kernel
import Contract

/// The *driver* for the `Infrastructure.Config` port — binds the config store
/// (`any ConfigStoring`) via the `@callable`-generated `ConfigStoringCallable.wire`.
///
/// Layer-prefixed because the `Config` port exists in both layers
/// (`Infrastructure.Config` and `Circuit.Config`); their drivers would otherwise
/// collide on type name within the package.
package struct InfrastructureConfigDriver {
    private let store: any ConfigStoring

    package init(store: any ConfigStoring) {
        self.store = store
    }

    package func wire(into builder: KernelBuilder) {
        ConfigStoringCallable.wire(store, into: builder)
    }
}
