import Foundation
import Kernel
import Contract
import Compute

/// The *driver* for the `Compute.Image` port — leaf handler over pure file filtering.
package struct ImageComputeDriver {
    package init() {}

    package func wire(into builder: KernelBuilder) {
        builder.register(Contract.Compute.Image.addDroppedFiles) { payload in
            ImageCompute().addDroppedFiles(payload)
        }
    }
}
