import Foundation

// MARK: - Slideshow Store
//
// The one open slideshow — the full, path-bearing unit (slides + config) that the
// editor and the player share. The peer of `LibraryState`: `library` is the
// path-free catalog (many summaries); `slideshow` is the single open detail.
// Loaded on demand by `Circuit.Slideshow.open` and cleared by `…close`, so at most
// one slideshow's slides (and their file paths) are resident at a time.
//
// The main window shows the home (list + editor) and the player mutually
// exclusively, so they can share this single slot. The sprite panel — the one
// surface that can coexist with the home — is seeded by value from the player it
// was launched from, so it does not contend for this slot.

/// Source of truth for the one open slideshow's full detail. `nil` while nothing
/// is open (or its load is still in flight); the editor and player read it,
/// guarding on `id` so a stale slot for a different slideshow reads as absent.
package struct SlideshowState: Sendable {
    package var slideshow: SlideshowReturn?

    package init(slideshow: SlideshowReturn? = nil) {
        self.slideshow = slideshow
    }
}
