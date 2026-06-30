import Kernel
import Contract

/// Pipeline: `Infrastructure.Library.fetch ▶ require-exists ▶ Compute.Slideshow.update ▶ Infrastructure.Library.save ▶ buffer.replace`
package func updateSlideshow(_ kernel: Kernel, _ payload: UpdateSlideshowPayload) async throws {
    try await kernel.run(
        pipeline(Callable.Infrastructure.Library.fetch)                        // UUID -> Slideshow?
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
            .tap(Callable.Infrastructure.Library.save)                         // persist, keep the Slideshow flowing
            .map(SlideshowReturn.init(from:))                            // project -> SlideshowReturn
            .effect { kernel, result in                                 // publish to the buffer
                await kernel.buffer.mutate(LibraryState.self) { state in
                    if let index = state.slideshows.firstIndex(where: { $0.id == result.id }) {
                        state.slideshows[index] = result
                    }
                }
            },
        payload.id
    )
}
