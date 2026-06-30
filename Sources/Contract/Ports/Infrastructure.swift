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
///
/// The slideshow persistence is split into two ports along the same
/// `library` / `slideshow` axis as Circuit/Compute: `LibraryStoring` (the path-free
/// catalog read) and `SlideshowStoring` (per-slideshow CRUD). One SwiftData actor
/// backs both — see `Infrastructure.swift`.

/// The library (catalog) store surface — the path-free list. Split from the
/// per-slideshow CRUD below so the two read along the same `library` / `slideshow`
/// axis as the Circuit and Compute ports.
@callable("Infrastructure.Library")
package protocol LibraryStoring: Sendable {
    /// Catalog read for the library list — counts slides without materializing
    /// their rows, so no file paths are loaded.
    func fetchSummaries() async throws -> [SlideshowSummary]
}

/// The single-slideshow store surface — the full, path-bearing unit's CRUD.
@callable("Infrastructure.Slideshow")
package protocol SlideshowStoring: Sendable {
    /// Load the full, path-bearing slideshow by id (nil if none exists).
    func fetch(id: UUID) async throws -> Slideshow?
    /// Persist the slideshow to the store (insert or replace by id).
    func save(_ slideshow: Slideshow) async throws
    /// Delete the slideshow with this id from the store.
    func delete(id: UUID) async throws
}

/// The config store surface.
@callable("Infrastructure.Config")
package protocol ConfigStoring: Sendable {
    /// Load the persisted global slideshow config.
    func load() async throws -> SlideshowConfig
    /// Persist the global slideshow config.
    func save(_ config: SlideshowConfig) async throws
}
