import Foundation
import SwiftData
import Contract

// MARK: - Package seam
//
// SwiftData's `@Model` / `@ModelActor` macros synthesise `internal` witnesses
// (`id`, `modelContainer`, `modelExecutor`), so the model classes and the
// @ModelActor repositories cannot themselves be `package` — they would violate
// "witness must be as accessible as its type". Instead we keep all SwiftData
// types internal to this module and expose a narrow package surface: protocols
// the Driver can hold, plus factories that build the concrete types here, where
// the internal initialisers are visible.

package protocol SlideshowStore: Sendable {
    func fetchAll() async throws -> [Slideshow]
    func fetch(id: UUID) async throws -> Slideshow?
    func save(_ slideshow: Slideshow) async throws
    func delete(id: UUID) async throws
}

package protocol ConfigStoring: Sendable {
    func load() async throws -> SlideshowConfig
    func save(_ config: SlideshowConfig) async throws
}

extension SlideshowRepository: SlideshowStore {}
extension ConfigStore: ConfigStoring {}

/// Builds the SwiftData container with the app's schema. The `@Model` types stay
/// internal — only this factory names them.
package func makeModelContainer(url: URL) throws -> ModelContainer {
    let configuration = ModelConfiguration(url: url)
    return try ModelContainer(
        for: SlideshowModel.self, SlideModel.self, ConfigModel.self,
        configurations: configuration
    )
}

package func makeSlideshowStore(_ container: ModelContainer) -> any SlideshowStore {
    SlideshowRepository(modelContainer: container)
}

package func makeConfigStore(_ container: ModelContainer) -> any ConfigStoring {
    ConfigStore(modelContainer: container)
}
