import Foundation
import Kernel

/// Port declarations for the Compute device — the computational resource.
///
/// Compute holds the pure business logic: building/transforming slideshows,
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
