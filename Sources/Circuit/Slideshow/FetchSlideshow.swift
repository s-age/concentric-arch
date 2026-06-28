import Kernel
import Contract

/// Pipeline: `Infrastructure.Library.fetch ▶ project`
package func fetchSlideshow(_ kernel: Kernel, _ payload: FetchSlideshowPayload) async throws -> SlideshowReturn? {
    try await kernel.compose(
        pipeline(Infrastructure.Library.fetch)              // UUID -> Slideshow?
            .map { $0.map(SlideshowReturn.init(from:)) },    // -> SlideshowReturn?
        payload.id
    )
}
