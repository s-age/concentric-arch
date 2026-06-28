import Foundation

// MARK: - Buffer state declarations
//
// The state types stored in `kernel.buffer`. The buffer is keyed by *type*, so
// each struct here is both the schema and the key for one Store. They live in
// `Contract` because both the writer (Circuit) and the reader (Presentation)
// depend on them — same downward-only direction as the `Symbol` ports.
//
// `Sendable` because values cross from an off-main writer into the `@MainActor`
// buffer; the `…Return` projections they hold are already `Sendable`.

/// Feature-unit Store for the Library screen.
///
/// Source of truth for the slideshow list and its loading flag, written by the
/// `Circuit.Slideshow` pipelines. UI-local concerns (the editor selection, error
/// banners) stay in the view model — Presentation only *reads* this.
package struct LibraryState: Sendable {
    package var slideshows: [SlideshowReturn]
    package var isLoading: Bool

    package init(slideshows: [SlideshowReturn] = [], isLoading: Bool = false) {
        self.slideshows = slideshows
        self.isLoading = isLoading
    }
}
