import Kernel
import Contract

/// Pipeline: `Infrastructure.Slideshow.delete ▶ buffer.remove`
package func deleteSlideshow(_ kernel: Kernel, _ payload: DeleteSlideshowPayload) async throws {
    try await kernel.run(
        pipeline(Callable.Infrastructure.Slideshow.delete)           // UUID -> Void
            .effect { kernel, _ in                          // remove from the buffer
                await kernel.buffer.mutate(LibraryState.self) { state in
                    state.slideshows.removeAll { $0.id == payload.id }
                }
                // Drop the open detail if it was the deleted one.
                await kernel.buffer.mutate(SlideshowState.self) { state in
                    if state.slideshow?.id == payload.id { state.slideshow = nil }
                }
            },
        payload.id
    )
}
