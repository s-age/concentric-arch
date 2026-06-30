import Kernel
import Contract

/// The Circuit module's catalog — the single self-descriptive index of what this
/// orchestration layer does. The conforming devices present its surface as
/// `LibraryCircuiting` / `SlideshowCircuiting` / `ConfigCircuiting` (so the
/// `@callable`-generated wiring can bind them); each operation delegates to its
/// saga in the per-pipeline files (`Slideshow/…`, `Config/…`). Open this file to
/// see every Circuit operation.
package struct LibraryCircuit: LibraryCircuiting {
    package init() {}
    package func fetchAll(_ kernel: Kernel, _ payload: FetchSlideshowsPayload) async throws { try await fetchSlideshows(kernel, payload) }
}

package struct SlideshowCircuit: SlideshowCircuiting {
    package init() {}
    package func create(_ kernel: Kernel, _ payload: CreateSlideshowPayload) async throws { try await createSlideshow(kernel, payload) }
    package func update(_ kernel: Kernel, _ payload: UpdateSlideshowPayload) async throws { try await updateSlideshow(kernel, payload) }
    package func updateConfig(_ kernel: Kernel, _ payload: UpdateSlideshowConfigPayload) async throws { try await updateSlideshowConfig(kernel, payload) }
    package func delete(_ kernel: Kernel, _ payload: DeleteSlideshowPayload) async throws { try await deleteSlideshow(kernel, payload) }
    package func open(_ kernel: Kernel, _ payload: OpenSlideshowPayload) async throws { try await openSlideshow(kernel, payload) }
    package func close(_ kernel: Kernel, _ payload: CloseSlideshowPayload) async throws { try await closeSlideshow(kernel, payload) }
}

package struct ConfigCircuit: ConfigCircuiting {
    package init() {}
    package func save(_ kernel: Kernel, _ payload: SaveConfigPayload) async throws { try await saveConfig(kernel, payload) }
}
