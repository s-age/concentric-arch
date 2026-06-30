import struct Foundation.UUID
import Kernel
import Contract

/// Pipeline: `Infrastructure.Slideshow.fetch ▶ require-exists ▶ Compute.Slideshow.applyConfig ▶ Infrastructure.Slideshow.save ▶ buffer.replace`
/// The pipeline as a value — split from execution so it can be introspected
/// without running. Captures `payload` (the requested config) in its closures.
package func updateSlideshowConfigPipe(_ payload: UpdateSlideshowConfigPayload) -> Pipe<UUID, SlideshowReturn> {
    pipeline(Callable.Infrastructure.Slideshow.fetch)                        // UUID -> Slideshow?
        .pipe { _, existing -> Verb<Slideshow> in                   // require it exists, else stop
            guard let existing else { return .fail(NotFoundError.slideshow(payload.slideshowID)) }
            return .next(existing)
        }
        .pipe(Callable.Compute.Slideshow.applyConfig) { existing in // transform with the requested config
            ApplyConfigComputePayload(
                current: existing,
                duration: payload.duration,
                transition: payload.transition,
                loop: payload.loop
            )
        }
        .tap(Callable.Infrastructure.Slideshow.save)                         // persist, keep the Slideshow flowing
        .map(SlideshowReturn.init(from:))                            // project -> SlideshowReturn
        .effect { kernel, result in                                 // publish to catalog + open detail
            await publishSlideshow(kernel, result)
        }
        .seal()
}

package func updateSlideshowConfig(_ kernel: Kernel, _ payload: UpdateSlideshowConfigPayload) async throws {
    try await kernel.run(updateSlideshowConfigPipe(payload), payload.slideshowID)
}
