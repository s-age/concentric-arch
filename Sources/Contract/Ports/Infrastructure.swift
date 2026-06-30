import Foundation
import Kernel

/// Port declarations for the Infrastructure (storage) device.
///
/// The two storing protocols are the device's operation surface and the single
/// source of truth: `@callable` generates the typed `Symbol`s + wiring (the peer
/// `SlideshowStoringCallable` / `ConfigStoringCallable` enums). The concrete
/// stores live in the `Infrastructure` module (SwiftData `@ModelActor`, kept
/// internal); they conform there and are injected as `any …Storing`.
///
/// The protocols live HERE rather than in Infrastructure so the generated symbols
/// sit in Contract — letting Circuit call them through the mesh without depending
/// on the Infrastructure module.

/// The slideshow store surface.
@callable("Infrastructure.Library")
package protocol SlideshowStoring: Sendable {
    func fetchAll() async throws -> [Slideshow]
    func fetch(id: UUID) async throws -> Slideshow?
    func save(_ slideshow: Slideshow) async throws
    func delete(id: UUID) async throws
}

/// The config store surface.
@callable("Infrastructure.Config")
package protocol ConfigStoring: Sendable {
    func load() async throws -> SlideshowConfig
    func save(_ config: SlideshowConfig) async throws
}
