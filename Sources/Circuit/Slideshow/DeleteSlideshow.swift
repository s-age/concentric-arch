import Kernel
import Contract

/// Pipeline: `Infrastructure.Library.delete ▶ buffer.remove`
package func deleteSlideshow(_ kernel: Kernel, _ payload: DeleteSlideshowPayload) async throws {
    try await kernel.run(
        pipeline(Infrastructure.Library.delete)             // UUID -> Void
            .effect { kernel, _ in                          // remove from the buffer
                await kernel.buffer.mutate(LibraryState.self) { state in
                    state.slideshows.removeAll { $0.id == payload.id }
                }
            },
        payload.id
    )
}
