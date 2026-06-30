import Kernel
import Contract

/// Pipeline: `build ▶ Infrastructure.Config.save`
package func saveConfig(_ kernel: Kernel, _ payload: SaveConfigPayload) async throws {
    let config = SlideshowConfig(
        duration: payload.duration.toEntity,
        transition: payload.transition.toEntity,
        loop: payload.loop
    )
    try await kernel.run(pipeline(ConfigStoringCallable.save), config) // SlideshowConfig -> Void (forward-only)
}
