import Kernel
import Contract

/// Pipeline: `build ▶ Infrastructure.Config.save`
/// The pipeline as a value — split from execution so it can be introspected
/// without running. No payload capture (input is the already-built config).
package func saveConfigPipe() -> Pipe<SlideshowConfig, Void> {
    pipeline(Callable.Infrastructure.Config.save).seal() // SlideshowConfig -> Void (forward-only)
}

package func saveConfig(_ kernel: Kernel, _ payload: SaveConfigPayload) async throws {
    let config = SlideshowConfig(
        duration: payload.duration.toEntity,
        transition: payload.transition.toEntity,
        loop: payload.loop
    )
    try await kernel.run(saveConfigPipe(), config)
}
