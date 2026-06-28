import Kernel
import Contract

/// Pipeline: `build ▶ Infrastructure.Config.save`
package func saveConfig(_ kernel: Kernel, _ payload: SaveConfigPayload) async throws {
    let config = SlideshowConfig(
        duration: payload.duration.toDomain,
        transition: payload.transition.toDomain,
        loop: payload.loop
    )
    try await kernel.run(pipeline(Infrastructure.Config.save), config) // SlideshowConfig -> Void (forward-only)
}
