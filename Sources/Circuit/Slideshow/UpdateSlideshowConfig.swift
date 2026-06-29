import Kernel
import Contract

/// Pipeline: `Infrastructure.Library.fetch ▶ require-exists ▶ Compute.Slideshow.applyConfig ▶ Infrastructure.Library.save ▶ buffer.replace`
package func updateSlideshowConfig(_ kernel: Kernel, _ payload: UpdateSlideshowConfigPayload) async throws {
    try await kernel.run(
        pipeline(Infrastructure.Library.fetch)                          // UUID -> Slideshow?
            .pipe { _, existing -> Verb<Slideshow> in                   // require it exists, else stop
                guard let existing else { return .fail(NotFoundError.slideshow(payload.slideshowID)) }
                return .next(existing)
            }
            .pipe(SlideshowComputingCallable.applyConfig) { existing in // transform with the requested config
                ApplyConfigComputePayload(
                    current: existing,
                    duration: payload.duration,
                    transition: payload.transition,
                    loop: payload.loop
                )
            }
            .tap(Infrastructure.Library.save)                           // persist, keep the Slideshow flowing
            .map(SlideshowReturn.init(from:))                            // project -> SlideshowReturn
            .effect { kernel, result in                                 // publish to the buffer
                await kernel.buffer.mutate(LibraryState.self) { state in
                    if let index = state.slideshows.firstIndex(where: { $0.id == result.id }) {
                        state.slideshows[index] = result
                    }
                }
            },
        payload.slideshowID
    )
}
