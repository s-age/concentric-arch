import Foundation
import Kernel
import Contract
import Compute

/// The *driver* for the `Compute.Slideshow` port — pure business logic, bound as
/// leaf handlers (`(P) -> O`, no kernel passed).
///
/// Port references are qualified `Contract.Compute.…` because this file imports
/// both the `Contract` module (the port enum) and the `Compute` module (the
/// logic) — same bare name.
package struct SlideshowComputeDriver {
    /// Held as the existential so only the `SlideshowComputing` surface is
    /// reachable here — the concrete `SlideshowCompute` and its privates can't
    /// leak into the wiring (reverse exactness). Defaulted because the compute
    /// device is pure (one impl, nothing to swap); injectable for tests.
    private let device: any SlideshowComputing

    package init(device: any SlideshowComputing = SlideshowCompute()) {
        self.device = device
    }

    package func wire(into builder: KernelBuilder) {
        // The wiring is generated from `SlideshowComputing`'s requirements by
        // `@callable` — one `register` per method, none can be forgotten.
        Callable.Compute.Slideshow.wire(device, into: builder)
    }
}
