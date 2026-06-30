import struct Foundation.UUID
import Kernel
import Contract

/// Pipeline: `Infrastructure.Slideshow.delete ▶ buffer.remove`
/// The pipeline as a value — split from execution so it can be introspected
/// without running. Captures `payload.id` in the buffer-removal effect.
package func deleteSlideshowPipe(_ payload: DeleteSlideshowPayload) -> Pipe<UUID, Void> {
    pipeline(Callable.Infrastructure.Slideshow.delete)           // UUID -> Void
        .effect(note: "remove catalog row + drop open detail") { kernel, _ in
            await kernel.buffer.mutate(LibraryState.self) { state in
                state.slideshows.removeAll { $0.id == payload.id }
            }
            // Drop the open detail if it was the deleted one.
            await kernel.buffer.mutate(SlideshowState.self) { state in
                if state.slideshow?.id == payload.id { state.slideshow = nil }
            }
        }
        .seal()
}

package func deleteSlideshow(_ kernel: Kernel, _ payload: DeleteSlideshowPayload) async throws {
    try await kernel.run(deleteSlideshowPipe(payload), payload.id)
}
