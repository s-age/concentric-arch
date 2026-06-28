import Foundation
import Kernel
import Contract
import Circuit

/// The *driver* for the `Circuit.Slideshow` port.
///
/// Each symbol maps to one orchestration pipeline (a `package` function in the
/// `Circuit` module). The kernel is handed in at call time — the same kernel the
/// pipeline then uses for its `Compute.*` / `Infrastructure.*` calls. That late
/// binding lets the orchestration share one kernel without a wiring cycle.
///
/// Port references are qualified `Contract.Circuit.…` (the `Contract` enum vs the
/// `Circuit` module share a bare name).
package struct SlideshowDriver {
    package init() {}

    package func wire(into builder: KernelBuilder) {
        builder.register(Contract.Circuit.Slideshow.create) { kernel, payload in
            try await createSlideshow(kernel, payload)
        }
        builder.register(Contract.Circuit.Slideshow.update) { kernel, payload in
            try await updateSlideshow(kernel, payload)
        }
        builder.register(Contract.Circuit.Slideshow.updateConfig) { kernel, payload in
            try await updateSlideshowConfig(kernel, payload)
        }
        builder.register(Contract.Circuit.Slideshow.fetchAll) { kernel, payload in
            try await fetchSlideshows(kernel, payload)
        }
        builder.register(Contract.Circuit.Slideshow.delete) { kernel, payload in
            try await deleteSlideshow(kernel, payload)
        }
    }
}
