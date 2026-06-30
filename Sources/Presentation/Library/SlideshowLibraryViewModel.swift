import Foundation
import Kernel
import Contract
import Observation

@Observable
@MainActor
package final class SlideshowLibraryViewModel {
    /// The list and its loading flag live in `kernel.buffer` (single source of
    /// truth, written by the `Circuit.Slideshow` pipelines). Presentation only
    /// reads them: reading the buffer inside these computed properties — evaluated
    /// in the SwiftUI body — registers the observation that drives re-render.
    var slideshows: [SlideshowReturn] { kernel.buffer.read(LibraryState.self).slideshows }
    var isLoading: Bool { kernel.buffer.read(LibraryState.self).isLoading }

    /// The slideshow currently open in the photo editor (right pane). UI-local
    /// selection, so it stays here rather than in the buffer.
    var selectedID: UUID?

    private let kernel: Kernel

    package init(kernel: Kernel) {
        self.kernel = kernel
    }

    var selectedSlideshow: SlideshowReturn? {
        guard let selectedID else { return nil }
        return slideshows.first { $0.id == selectedID }
    }

    func loadLibrary() async {
        // Fire-and-forget command: the pipeline writes the list (and isLoading)
        // into the buffer; observation refreshes the UI, and a failure surfaces in
        // the global banner via the kernel's error sink.
        kernel.dispatch(SlideshowCircuitingCallable.fetchAll, FetchSlideshowsPayload())
    }

    /// Creates an empty slideshow, persists it, and opens it for editing.
    func createSlideshow() async {
        // Presentation mints the identity, so "which one to open" is known here —
        // no return value to consume, no buffer channel. The pipeline appends the
        // new slideshow to the buffer; the list refreshes via observation.
        let id = UUID()
        kernel.dispatch(
            SlideshowCircuitingCallable.create,
            CreateSlideshowPayload(
                id: id,
                name: "New Slideshow",
                localIdentifiers: [],
                duration: .five,
                transition: .fade,
                loop: true
            )
        )
        selectedID = id
    }

    func rename(_ slideshow: SlideshowReturn, to name: String) async {
        await apply(to: slideshow, name: name, identifiers: slideshow.slides.map(\.localIdentifier))
    }

    func addPhotos(_ urls: [URL]) async {
        guard let slideshow = selectedSlideshow else { return }
        let existing = slideshow.slides.map(\.localIdentifier)
        let added = (try? await kernel.call(
            ImageComputingCallable.addDroppedFiles,
            AddDroppedFilesPayload(urls: urls, existingIdentifiers: existing)
        )) ?? []
        guard !added.isEmpty else { return }
        await apply(to: slideshow, name: slideshow.name, identifiers: existing + added)
    }

    func removePhoto(_ identifier: String) async {
        guard let slideshow = selectedSlideshow else { return }
        let identifiers = slideshow.slides.map(\.localIdentifier).filter { $0 != identifier }
        await apply(to: slideshow, name: slideshow.name, identifiers: identifiers)
    }

    func movePhoto(fromIndex: Int, toIndex: Int) async {
        guard let slideshow = selectedSlideshow else { return }
        var identifiers = slideshow.slides.map(\.localIdentifier)
        guard fromIndex != toIndex,
              identifiers.indices.contains(fromIndex),
              identifiers.indices.contains(toIndex) else { return }
        let item = identifiers.remove(at: fromIndex)
        identifiers.insert(item, at: toIndex)
        await apply(to: slideshow, name: slideshow.name, identifiers: identifiers)
    }

    func delete(id: UUID) async {
        // The pipeline removes it from the buffer; we only manage local selection.
        kernel.dispatch(SlideshowCircuitingCallable.delete, DeleteSlideshowPayload(id: id))
        if selectedID == id { selectedID = nil }
    }

    // MARK: - Private

    /// Persists a name/photo change. The pipeline updates the slideshow in the
    /// buffer in place, so there is nothing to splice here.
    private func apply(to slideshow: SlideshowReturn, name: String, identifiers: [String]) async {
        kernel.dispatch(
            SlideshowCircuitingCallable.update,
            UpdateSlideshowPayload(id: slideshow.id, name: name, localIdentifiers: identifiers)
        )
    }
}
