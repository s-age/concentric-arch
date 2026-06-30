import Kernel
import Contract

/// Wire every driver into the builder — the single entry point the App calls at
/// startup. Infra-backed drivers take their store by argument; the compute and
/// circuit drivers are constructed internally (pure / orchestration, nothing to
/// inject). Each driver's own `wire(into:)` installs its handlers — for the
/// `@callable`-generated devices that wiring is itself generated from the device
/// protocol, so no operation can be left unbound.
package func wireAllDrivers(
    into builder: KernelBuilder,
    slideshowStore: any LibraryStoring & SlideshowStoring,
    config: any ConfigStoring
) {
    // Infrastructure ports (leaf handlers → stores). One SwiftData actor backs both
    // slideshow ports: Library (catalog read) and Slideshow (per-slideshow CRUD).
    InfrastructureLibraryDriver(store: slideshowStore).wire(into: builder)
    InfrastructureSlideshowDriver(store: slideshowStore).wire(into: builder)
    InfrastructureConfigDriver(store: config).wire(into: builder)
    // Compute device (leaf handlers → pure business logic).
    SlideshowComputeDriver().wire(into: builder)
    ImageComputeDriver().wire(into: builder)
    // Circuit device (composing handlers → orchestration that routes via the kernel).
    CircuitLibraryDriver().wire(into: builder)
    CircuitSlideshowDriver().wire(into: builder)
    CircuitConfigDriver().wire(into: builder)
}
