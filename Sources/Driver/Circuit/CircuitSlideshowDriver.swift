import Kernel
import Contract
import Circuit

/// The *driver* for the `Circuit.Slideshow` port — binds the orchestration device
/// (`any SlideshowCircuiting`) via the `@callable`-generated `wire` (composing:
/// the kernel is handed to each handler at call time). The concrete
/// `SlideshowCircuit` delegates to the saga functions in the `Circuit` module.
///
/// Layer-prefixed (`Circuit…`) to avoid colliding with the Infrastructure
/// slideshow driver, since the `Slideshow` name is shared across both layers.
package struct CircuitSlideshowDriver {
    private let circuit: any SlideshowCircuiting

    package init(circuit: any SlideshowCircuiting = SlideshowCircuit()) {
        self.circuit = circuit
    }

    package func wire(into builder: KernelBuilder) {
        Callable.Circuit.Slideshow.wire(circuit, into: builder)
    }
}
