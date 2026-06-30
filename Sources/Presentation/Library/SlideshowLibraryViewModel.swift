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
    var slideshows: [SlideshowSummaryReturn] { kernel.buffer.read(LibraryState.self).slideshows }
    var isLoading: Bool { kernel.buffer.read(LibraryState.self).isLoading }

    /// The slideshow currently open in the photo editor (right pane). UI-local
    /// selection, so it stays here rather than in the buffer.
    var selectedID: UUID?

    /// A slideshow this view model just created: the `create` pipeline already wrote
    /// it into `SlideshowState`, so the selection-driven `openSelected()` must not
    /// re-fetch it. Cleared the first time `openSelected()` sees it. (One synchronous
    /// flag — `create` and `open` are different commands, so the kernel's per-command
    /// coalescing can't relate them.)
    private var justCreatedID: UUID?

    private let kernel: Kernel

    package init(kernel: Kernel) {
        self.kernel = kernel
    }

    /// The full, path-bearing detail of the selected slideshow. It lives in
    /// `SlideshowState` (loaded on demand by `openSelected()`), not in the
    /// path-free catalog — so we guard on `id` to ignore a slot that currently
    /// holds a different slideshow (or is still loading).
    var selectedSlideshow: SlideshowReturn? {
        guard let selectedID else { return nil }
        let open = kernel.buffer.read(SlideshowState.self).slideshow
        return open?.id == selectedID ? open : nil
    }

    /// Load the selected slideshow's detail into `SlideshowState`, unless the slot
    /// already holds it. Driven by the editor's `.task(id: selectedID)`. No manual
    /// dedupe: the slot check skips the no-op (already open, e.g. just created or
    /// returned from the player onto the same one), and the kernel coalesces any
    /// duplicate `open` that a selection flicker / double-click still emits.
    ///
    /// Deselect (nil) intentionally does nothing — the slot keeps the last opened
    /// slideshow (at most one resident), and not firing `close` here avoids the
    /// open/close churn a transient selection nil would cause.
    func openSelected() async {
        guard let selectedID else { return }
        // Just created: `create` already populated the slot — skip the redundant open
        // (and consume the flag so a later re-select opens normally).
        if justCreatedID == selectedID { justCreatedID = nil; return }
        guard kernel.buffer.read(SlideshowState.self).slideshow?.id != selectedID else { return }
        kernel.dispatch(Callable.Circuit.Slideshow.open, OpenSlideshowPayload(id: selectedID))
    }

    func loadLibrary() async {
        // Fire-and-forget command: the pipeline writes the list (and isLoading)
        // into the buffer; observation refreshes the UI, and a failure surfaces in
        // the global banner via the kernel's error sink.
        kernel.dispatch(Callable.Circuit.Library.fetchAll, FetchSlideshowsPayload())
    }

    /// Creates an empty slideshow, persists it, and opens it for editing.
    func createSlideshow() async {
        // Presentation mints the identity, so "which one to open" is known here —
        // no return value to consume, no buffer channel. The pipeline appends the
        // new slideshow to the buffer; the list refreshes via observation.
        let id = UUID()
        // The create pipeline writes the new slideshow straight into `SlideshowState`;
        // flag it so the selection-driven `openSelected()` doesn't re-fetch it.
        justCreatedID = id
        kernel.dispatch(
            Callable.Circuit.Slideshow.create,
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

    /// Renames any catalog row. The row carries no slides (it's a summary), so we
    /// pass `nil` identifiers — the `update` pipeline keeps the persisted slides
    /// untouched and only changes the name.
    func rename(_ slideshow: SlideshowSummaryReturn, to name: String) async {
        await apply(id: slideshow.id, name: name, identifiers: nil)
    }

    func addPhotos(_ urls: [URL]) async {
        guard let slideshow = selectedSlideshow else { return }
        let existing = slideshow.slides.map(\.localIdentifier)
        let added = (try? await kernel.call(
            Callable.Compute.Image.addDroppedFiles,
            AddDroppedFilesPayload(urls: urls, existingIdentifiers: existing)
        )) ?? []
        guard !added.isEmpty else { return }
        await apply(id: slideshow.id, name: slideshow.name, identifiers: existing + added)
    }

    func removePhoto(_ identifier: String) async {
        guard let slideshow = selectedSlideshow else { return }
        let identifiers = slideshow.slides.map(\.localIdentifier).filter { $0 != identifier }
        await apply(id: slideshow.id, name: slideshow.name, identifiers: identifiers)
    }

    func movePhoto(fromIndex: Int, toIndex: Int) async {
        guard let slideshow = selectedSlideshow else { return }
        var identifiers = slideshow.slides.map(\.localIdentifier)
        guard fromIndex != toIndex,
              identifiers.indices.contains(fromIndex),
              identifiers.indices.contains(toIndex) else { return }
        let item = identifiers.remove(at: fromIndex)
        identifiers.insert(item, at: toIndex)
        await apply(id: slideshow.id, name: slideshow.name, identifiers: identifiers)
    }

    func delete(id: UUID) async {
        // The pipeline removes it from the buffer; we only manage local selection.
        kernel.dispatch(Callable.Circuit.Slideshow.delete, DeleteSlideshowPayload(id: id))
        if selectedID == id { selectedID = nil }
    }

    // MARK: - Private

    /// Persists a name/photo change. The pipeline updates both Stores (catalog +
    /// open detail) in place, so there is nothing to splice here. `identifiers ==
    /// nil` means "keep the existing slides" (a pure rename).
    private func apply(id: UUID, name: String, identifiers: [String]?) async {
        kernel.dispatch(
            Callable.Circuit.Slideshow.update,
            UpdateSlideshowPayload(id: id, name: name, localIdentifiers: identifiers)
        )
    }
}
