import Kernel
import Contract

/// Concrete Circuit devices: thin conformers that present the saga functions as
/// the `@callable`-generated operation surface. The orchestration bodies stay in
/// the per-pipeline files (`Slideshow/…`, `Config/…`); these types just expose
/// them as `SlideshowCircuiting` / `ConfigCircuiting` so the macro can wire them.
package struct SlideshowCircuit: SlideshowCircuiting {
    package init() {}
    package func create(_ kernel: Kernel, _ payload: CreateSlideshowPayload) async throws { try await createSlideshow(kernel, payload) }
    package func update(_ kernel: Kernel, _ payload: UpdateSlideshowPayload) async throws { try await updateSlideshow(kernel, payload) }
    package func updateConfig(_ kernel: Kernel, _ payload: UpdateSlideshowConfigPayload) async throws { try await updateSlideshowConfig(kernel, payload) }
    package func fetchAll(_ kernel: Kernel, _ payload: FetchSlideshowsPayload) async throws { try await fetchSlideshows(kernel, payload) }
    package func delete(_ kernel: Kernel, _ payload: DeleteSlideshowPayload) async throws { try await deleteSlideshow(kernel, payload) }
}

package struct ConfigCircuit: ConfigCircuiting {
    package init() {}
    package func save(_ kernel: Kernel, _ payload: SaveConfigPayload) async throws { try await saveConfig(kernel, payload) }
}
