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

/// The slideshow orchestration surface. Forward-only commands (Void): they publish
/// into `LibraryState` and Presentation observes it.
@callable("Circuit.Slideshow")
package protocol SlideshowCircuiting: Sendable {
    func create(_ kernel: Kernel, _ payload: CreateSlideshowPayload) async throws
    func update(_ kernel: Kernel, _ payload: UpdateSlideshowPayload) async throws
    func updateConfig(_ kernel: Kernel, _ payload: UpdateSlideshowConfigPayload) async throws
    func fetchAll(_ kernel: Kernel, _ payload: FetchSlideshowsPayload) async throws
    func delete(_ kernel: Kernel, _ payload: DeleteSlideshowPayload) async throws
}

/// The config orchestration surface.
@callable("Circuit.Config")
package protocol ConfigCircuiting: Sendable {
    func save(_ kernel: Kernel, _ payload: SaveConfigPayload) async throws
}
