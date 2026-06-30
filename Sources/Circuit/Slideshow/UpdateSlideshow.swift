import Kernel
import Contract

/// Pipeline: `Infrastructure.Slideshow.fetch ▶ require-exists ▶ Compute.Slideshow.update ▶ Infrastructure.Slideshow.save ▶ buffer.replace`
package func updateSlideshow(_ kernel: Kernel, _ payload: UpdateSlideshowPayload) async throws {
    try await kernel.run(
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
            },
        payload.id
    )
}
