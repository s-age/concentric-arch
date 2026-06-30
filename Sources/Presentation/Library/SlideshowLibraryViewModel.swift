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

    /// The id we last asked `open` to load while the slot was still empty — used to
    /// dedupe rapid `.task(id:)` re-fires (e.g. the `List` selection thrashing when
    /// a freshly-created row is selected before it exists in the catalog).
    private var pendingOpenID: UUID?

    /// Whether a `close` is already in flight — dedupes the same `.task(id:)` re-fire
    /// on the deselect side (clicking outside the list can run `openSelected(nil)`
    /// more than once before the slot is cleared).
    private var pendingClose = false

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

    /// The raw id currently in the open slot, regardless of selection — observed by
    /// the editor to drive `slotDidSettle()` when the slot loads or clears (the
    /// selection-guarded `selectedSlideshow` can't see the slot clearing on close).
    var openSlideshowID: UUID? { kernel.buffer.read(SlideshowState.self).slideshow?.id }

    /// Bring `SlideshowState` in line with the current selection. Driven by the
    /// editor's `.task(id: selectedID)`, so it fires on selection change and when
    /// the home view re-appears (e.g. returning from the player, which may have
    /// left a different slideshow in the slot).
    func openSelected() async {
        let current = kernel.buffer.read(SlideshowState.self).slideshow
        guard let selectedID else {
            // Genuine deselect — free the slot once. Skip while an open is in flight
            // (a double-click momentarily clears then re-sets selection; we mustn't
            // wipe the slideshow we're loading), and skip if a close is already in
            // flight (dedupes the repeat `openSelected(nil)` before the slot clears).
            if pendingOpenID == nil, !pendingClose, current != nil {
                pendingClose = true
                kernel.dispatch(Callable.Circuit.Slideshow.close, CloseSlideshowPayload())
            }
            return
        }
        pendingClose = false
        // Already the open slideshow (the player/create just loaded it) — nothing to do.
        if current?.id == selectedID {
            pendingOpenID = nil
            return
        }
        // An open for this id is already in flight: dedupe the repeat request. The
        // marker is cleared by `slotDidSettle()` once the slot reflects the load, so
        // this only matches a dispatch that hasn't landed yet — covering both the
        // double-click flicker and a just-created row whose List selection thrashes.
        // A genuine change (a different id, e.g. the player left another in the slot)
        // has `pendingOpenID != selectedID`, so it still re-opens.
        if pendingOpenID == selectedID { return }
        pendingOpenID = selectedID
        kernel.dispatch(Callable.Circuit.Slideshow.open, OpenSlideshowPayload(id: selectedID))
    }

    /// Clear the in-flight marker once the open slot reflects what we asked to open.
    /// Driven by the editor observing `SlideshowState`, so a later selection that
    /// needs a real re-open (returning from the player, which loaded a different
    /// slideshow) isn't wrongly deduped.
    func slotDidSettle() {
        let id = kernel.buffer.read(SlideshowState.self).slideshow?.id
        if id == pendingOpenID { pendingOpenID = nil }
        if id == nil { pendingClose = false }   // the close landed
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
        // The create pipeline writes the new slideshow straight into `SlideshowState`,
        // so the editor needs no separate `open`. Pre-seed `pendingOpenID` so the
        // selection-driven `.task(id:)` skips its (redundant) fetch while create is
        // still in flight and the catalog row doesn't yet exist.
        pendingOpenID = id
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
        if selectedID == id {
            selectedID = nil
            pendingOpenID = nil
        }
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
