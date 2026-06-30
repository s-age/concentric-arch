import Foundation
import Contract

/// Pure business logic for building and transforming slideshows. No I/O, no kernel
/// calls — a leaf computation. Wired into the kernel by `SlideshowComputeDriver`.
package struct SlideshowCompute: SlideshowComputing {
    package init() {}

    package func create(_ payload: CreateSlideshowPayload) -> Slideshow {
        let config = SlideshowConfig(
            duration: payload.duration.toEntity,
            transition: payload.transition.toEntity,
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
        // `nil` is a pure rename — keep the existing slides. A value replaces them.
        if let identifiers = payload.localIdentifiers {
            updated.slides = Self.makeSlides(
                from: identifiers,
                duration: updated.config.duration.seconds ?? 0
            )
        }
        return updated
    }

    package func applyConfig(_ payload: ApplyConfigComputePayload) -> Slideshow {
        var updated = payload.current
        updated.config = SlideshowConfig(
            duration: payload.duration.toEntity,
            transition: payload.transition.toEntity,
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
