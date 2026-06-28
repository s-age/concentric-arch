import Foundation
import Kernel

/// Port declarations for the Compute device — the computational resource.
///
/// Compute holds the pure domain logic: building/transforming slideshows,
/// playback index math, image filtering. Every op is a leaf (no I/O, no further
/// kernel calls). Handlers live in `Driver/Compute/`; the logic lives in the
/// `Compute` module.
package enum Compute {
    package enum Slideshow {
        package static let create      = Symbol<CreateSlideshowPayload, Contract.Slideshow>("Compute.Slideshow.create")
        package static let update       = Symbol<UpdateSlideshowComputePayload, Contract.Slideshow>("Compute.Slideshow.update")
        package static let applyConfig  = Symbol<ApplyConfigComputePayload, Contract.Slideshow>("Compute.Slideshow.applyConfig")
    }

    package enum Image {
        package static let addDroppedFiles = Symbol<AddDroppedFilesPayload, [String]>("Compute.Image.addDroppedFiles")
    }
}

// MARK: - Compute payloads
//
// Transform ops bundle the current `Slideshow` data with the requested change,
// since Compute is stateless and receives everything it needs as data.

package struct UpdateSlideshowComputePayload {
    package let current: Slideshow
    package let name: String
    package let localIdentifiers: [String]

    package init(current: Slideshow, name: String, localIdentifiers: [String]) {
        self.current = current
        self.name = name
        self.localIdentifiers = localIdentifiers
    }
}

package struct ApplyConfigComputePayload {
    package let current: Slideshow
    package let duration: SlideDurationReturn
    package let transition: TransitionTypeReturn
    package let loop: Bool

    package init(current: Slideshow, duration: SlideDurationReturn, transition: TransitionTypeReturn, loop: Bool) {
        self.current = current
        self.duration = duration
        self.transition = transition
        self.loop = loop
    }
}
