import Kernel
import Contract
import Circuit

/// The *driver* for the `Circuit.Slideshow` port — binds the orchestration device
/// (`any SlideshowCircuiting`) via the `@callable`-generated `wire` (composing:
/// the kernel is handed to each handler at call time). The concrete
/// `SlideshowCircuit` delegates to the saga functions in the `Circuit` module.
package struct SlideshowDriver {
    private let circuit: any SlideshowCircuiting

    package init(circuit: any SlideshowCircuiting = SlideshowCircuit()) {
        self.circuit = circuit
    }

    package func wire(into builder: KernelBuilder) {
        SlideshowCircuitingCallable.wire(circuit, into: builder)
    }
}
