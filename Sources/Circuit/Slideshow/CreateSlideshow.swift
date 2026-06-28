import Kernel
import Contract

/// Pipeline: `Compute.Slideshow.create ▶ Infrastructure.Library.save ▶ buffer.append`
package func createSlideshow(_ kernel: Kernel, _ payload: CreateSlideshowPayload) async throws {
    try await kernel.run(
        pipeline(Compute.Slideshow.create)          // CreateSlideshowPayload -> Slideshow
            .tap(Infrastructure.Library.save)       // persist, keep the Slideshow flowing
            .map(SlideshowReturn.init(from:))        // project -> SlideshowReturn
            .effect { kernel, created in             // publish to the buffer
                await kernel.buffer.mutate(LibraryState.self) { $0.slideshows.append(created) }
            },
        payload
    )
}
