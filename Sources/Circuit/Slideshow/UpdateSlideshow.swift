import struct Foundation.UUID
import Kernel
import Contract

/// Pipeline: `Infrastructure.Slideshow.fetch ▶ require-exists ▶ Compute.Slideshow.update ▶ Infrastructure.Slideshow.save ▶ buffer.replace`
/// The pipeline as a value — split from execution so it can be introspected
/// without running. Captures `payload` (the requested change) in the adapt/guard
/// closures, so it takes the payload; introspection builds it with a throwaway
/// payload and reads only the static shape.
package func updateSlideshowPipe(_ payload: UpdateSlideshowPayload) -> Pipe<UUID, SlideshowReturn> {
    pipeline(Callable.Infrastructure.Slideshow.fetch)                        // UUID -> Slideshow?
        .pipe { _, existing -> Verb<Slideshow> in                   // require it exists, else stop
            guard let existing else { return .fail(NotFoundError.slideshow(payload.id)) }
            return .next(existing)
        }
        .pipe(Callable.Compute.Slideshow.update) { existing in      // transform with the requested change
            UpdateSlideshowComputePayload(
                current: existing,
                name: payload.name,
                localIdentifiers: payload.localIdentifiers
            )
        }
        .tap(Callable.Infrastructure.Slideshow.save)                         // persist, keep the Slideshow flowing
        .map(SlideshowReturn.init(from:))                            // project -> SlideshowReturn
        .effect { kernel, result in                                 // publish to catalog + open detail
            await publishSlideshow(kernel, result)
        }
        .seal()
}

package func updateSlideshow(_ kernel: Kernel, _ payload: UpdateSlideshowPayload) async throws {
    try await kernel.run(updateSlideshowPipe(payload), payload.id)
}
