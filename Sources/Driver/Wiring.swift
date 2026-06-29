import Kernel
import Infrastructure

/// Wire every driver into the builder — the single entry point the App calls at
/// startup. Infra-backed drivers take their store by argument; the compute and
/// circuit drivers are constructed internally (pure / orchestration, nothing to
/// inject). Each driver's own `wire(into:)` installs its handlers — for the
/// `@callable`-generated devices that wiring is itself generated from the device
/// protocol, so no operation can be left unbound.
package func wireAllDrivers(
    into builder: KernelBuilder,
    library: any SlideshowStoring,
    config: any ConfigStoring
) {
    // Infrastructure ports (leaf handlers → repositories/stores).
    LibraryDriver(repository: library).wire(into: builder)
    InfrastructureConfigDriver(store: config).wire(into: builder)
    // Compute device (leaf handlers → pure business logic).
    SlideshowComputeDriver().wire(into: builder)
    ImageComputeDriver().wire(into: builder)
    // Circuit device (composing handlers → orchestration that routes via the kernel).
    SlideshowDriver().wire(into: builder)
    CircuitConfigDriver().wire(into: builder)
}
