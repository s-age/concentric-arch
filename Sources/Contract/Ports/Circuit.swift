import Foundation
import Kernel

/// Port declarations for the Circuit device — the orchestration layer.
///
/// Circuit is "just a circuit": it routes between other devices via the kernel
/// (`Compute.*` for logic, `Infrastructure.*` for I/O) and enforces flow rules,
/// but holds no business logic itself. Its operations are *composing* — they take
/// the `Kernel` so they can route back into the mesh — which `@callable` binds via
/// the composing `register` overload. The conforming types live in the `Circuit`
/// module and delegate to the saga functions there.

/// The library (catalog) orchestration surface — the list as a whole. Split from
/// the per-slideshow surface below along the same `library` / `slideshow` axis as
/// the Infrastructure ports. Forward-only: publishes into `LibraryState`.
@callable("Circuit.Library")
package protocol LibraryCircuiting: Sendable {
    func fetchAll(_ kernel: Kernel, _ payload: FetchSlideshowsPayload) async throws
}

/// The single-slideshow orchestration surface — one slideshow's lifecycle and its
/// open detail. Forward-only commands (Void): they publish into `LibraryState`
/// (the catalog row) and `SlideshowState` (the open detail); Presentation observes.
@callable("Circuit.Slideshow")
package protocol SlideshowCircuiting: Sendable {
    func create(_ kernel: Kernel, _ payload: CreateSlideshowPayload) async throws
    func update(_ kernel: Kernel, _ payload: UpdateSlideshowPayload) async throws
    func updateConfig(_ kernel: Kernel, _ payload: UpdateSlideshowConfigPayload) async throws
    func delete(_ kernel: Kernel, _ payload: DeleteSlideshowPayload) async throws
    /// Load one slideshow's full detail into `SlideshowState` (on demand).
    func open(_ kernel: Kernel, _ payload: OpenSlideshowPayload) async throws
    /// Clear `SlideshowState` so no slideshow's slides stay resident.
    func close(_ kernel: Kernel, _ payload: CloseSlideshowPayload) async throws
}

/// The config orchestration surface.
@callable("Circuit.Config")
package protocol ConfigCircuiting: Sendable {
    func save(_ kernel: Kernel, _ payload: SaveConfigPayload) async throws
}
