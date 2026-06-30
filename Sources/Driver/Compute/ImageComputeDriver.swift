import Foundation
import Kernel
import Contract
import Compute

/// The *driver* for the `Compute.Image` port — leaf handler over pure file filtering.
package struct ImageComputeDriver {
    /// Existential surface only (reverse exactness). Defaulted (pure device),
    /// injectable for tests.
    private let device: any ImageComputing

    package init(device: any ImageComputing = ImageCompute()) {
        self.device = device
    }

    package func wire(into builder: KernelBuilder) {
        ImageComputingCallable.wire(device, into: builder)
    }
}
