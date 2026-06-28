import Foundation
import Kernel
import Contract
import Compute

/// The *driver* for the `Compute.Slideshow` port — pure domain logic, bound as
/// leaf handlers (`(P) -> O`, no kernel passed).
///
/// Port references are qualified `Contract.Compute.…` because this file imports
/// both the `Contract` module (the port enum) and the `Compute` module (the
/// logic) — same bare name.
package struct SlideshowComputeDriver {
    package init() {}

    package func wire(into builder: KernelBuilder) {
        builder.register(Contract.Compute.Slideshow.create) { payload in
            SlideshowCompute().create(payload)
        }
        builder.register(Contract.Compute.Slideshow.update) { payload in
            SlideshowCompute().update(payload)
        }
        builder.register(Contract.Compute.Slideshow.applyConfig) { payload in
            SlideshowCompute().applyConfig(payload)
        }
    }
}
