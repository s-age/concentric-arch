import Foundation
import Kernel

/// Port declarations for the Compute device — the computational resource.
///
/// Compute holds pure business logic (no I/O, no kernel calls). The two device
/// protocols below ARE the port surface, and they are the single source of truth:
/// `@callable` generates, from each protocol's method requirements, the typed
/// `Symbol`s and the wiring (see the generated `SlideshowComputingCallable` /
/// `ImageComputingCallable`). Conformance forces the implementations (forward
/// exactness); consuming the device as `any …Computing` forces the surface
/// (reverse exactness); the macro forces the dispatch keys + wiring to match —
/// one `register` per requirement, so none can be forgotten. There is no separate
/// id list to drift.

/// The Slideshow compute device's operation surface.
@callable("Compute.Slideshow")
package protocol SlideshowComputing: Sendable {
    func create(_ payload: CreateSlideshowPayload) -> Slideshow
    func update(_ payload: UpdateSlideshowComputePayload) -> Slideshow
    func applyConfig(_ payload: ApplyConfigComputePayload) -> Slideshow
}

/// The Image compute device's operation surface.
@callable("Compute.Image")
package protocol ImageComputing: Sendable {
    func addDroppedFiles(_ payload: AddDroppedFilesPayload) -> [String]
}
