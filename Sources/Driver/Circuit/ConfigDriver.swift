import Kernel
import Contract
import Circuit

/// The *driver* for the `Circuit.Config` port — binds the orchestration device
/// (`any ConfigCircuiting`) via the `@callable`-generated `wire`.
///
/// Layer-prefixed (`Circuit…`) to avoid colliding with the Infrastructure config
/// driver, since the `Config` port name is shared across both layers.
package struct CircuitConfigDriver {
    private let circuit: any ConfigCircuiting

    package init(circuit: any ConfigCircuiting = ConfigCircuit()) {
        self.circuit = circuit
    }

    package func wire(into builder: KernelBuilder) {
        Callable.Circuit.Config.wire(circuit, into: builder)
    }
}
