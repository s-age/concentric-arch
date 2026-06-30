import Kernel
import Contract
import Circuit

/// The *driver* for the `Circuit.Library` port — the catalog orchestration (the
/// list as a whole). Binds the composing device (`any LibraryCircuiting`) via the
/// `@callable`-generated `wire`; the concrete `LibraryCircuit` delegates to the
/// fetch saga in the `Circuit` module.
///
/// Layer-prefixed because `Library` now names a device in both the Circuit and
/// Infrastructure layers.
package struct CircuitLibraryDriver {
    private let circuit: any LibraryCircuiting

    package init(circuit: any LibraryCircuiting = LibraryCircuit()) {
        self.circuit = circuit
    }

    package func wire(into builder: KernelBuilder) {
        Callable.Circuit.Library.wire(circuit, into: builder)
    }
}
