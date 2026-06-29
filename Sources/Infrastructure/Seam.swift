import Foundation
import SwiftData
import Contract

// MARK: - Package seam
//
// SwiftData's `@Model` / `@ModelActor` macros synthesise `internal` witnesses
// (`id`, `modelContainer`, `modelExecutor`), so the model classes and the
// @ModelActor stores cannot themselves be `package` — they would violate
// "witness must be as accessible as its type". Instead we keep all SwiftData
// types internal to this module and expose a narrow package surface: the concrete
// stores conform to the `SlideshowStoring` / `ConfigStoring` protocols (declared
// in Contract, where `@callable` generates their dispatch symbols), plus factories
// that build the concrete types here, where the internal initialisers are visible.

extension SlideshowStore: SlideshowStoring {}
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

package func makeSlideshowStore(_ container: ModelContainer) -> any SlideshowStoring {
    SlideshowStore(modelContainer: container)
}

package func makeConfigStore(_ container: ModelContainer) -> any ConfigStoring {
    ConfigStore(modelContainer: container)
}
