import Foundation
import Contract

/// Pure domain logic for building and transforming slideshows. No I/O, no kernel
/// calls — a leaf computation. Wired into the kernel by `SlideshowComputeDriver`.
package struct SlideshowCompute {
    package init() {}

    package func create(_ payload: CreateSlideshowPayload) -> Slideshow {
        let config = SlideshowConfig(
            duration: payload.duration.toDomain,
            transition: payload.transition.toDomain,
            loop: payload.loop
        )
        return Slideshow(
            id: payload.id,
            name: payload.name,
            slides: Self.makeSlides(from: payload.localIdentifiers, duration: config.duration.seconds ?? 0),
            config: config,
            createdAt: Date()
        )
    }

    package func update(_ payload: UpdateSlideshowComputePayload) -> Slideshow {
        var updated = payload.current
        updated.name = payload.name
        updated.slides = Self.makeSlides(
            from: payload.localIdentifiers,
            duration: updated.config.duration.seconds ?? 0
        )
        return updated
    }

    package func applyConfig(_ payload: ApplyConfigComputePayload) -> Slideshow {
        var updated = payload.current
        updated.config = SlideshowConfig(
            duration: payload.duration.toDomain,
            transition: payload.transition.toDomain,
            loop: payload.loop
        )
        return updated
    }

    // MARK: - Private

    private static func makeSlides(from localIdentifiers: [String], duration: TimeInterval) -> [Slide] {
        localIdentifiers.enumerated().map { index, id in
            Slide(id: UUID(), localIdentifier: id, order: index, duration: duration, title: nil)
        }
    }
}
