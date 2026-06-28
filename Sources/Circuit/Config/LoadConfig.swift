import Kernel
import Contract

/// Pipeline: `Infrastructure.Config.load ▶ project`
package func loadConfig(_ kernel: Kernel, _ payload: LoadConfigPayload) async throws -> SlideshowConfigReturn {
    try await kernel.compose(
        pipeline(Infrastructure.Config.load)                // Void -> SlideshowConfig
            .map(SlideshowConfigReturn.init(from:)),         // -> SlideshowConfigReturn
        ()
    )
}
