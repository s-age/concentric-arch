import struct Foundation.UUID
import Kernel
import Contract

/// Pipeline: `Infrastructure.Slideshow.fetch ▶ require-exists ▶ project ▶ buffer.write(SlideshowState)`
///
/// On-demand detail load: the catalog in `LibraryState` is path-free, so the
/// editor and player ask for the full, path-bearing slideshow only when one is
/// actually opened. The result lands in the single `SlideshowState` slot.
/// The pipeline as a value — split from execution so it can be introspected
/// without running. Captures `payload.id` in the guard's error.
package func openSlideshowPipe(_ payload: OpenSlideshowPayload) -> Pipe<UUID, SlideshowReturn> {
    pipeline(Callable.Infrastructure.Slideshow.fetch)                 // UUID -> Slideshow?
        .pipe { _, existing -> Verb<Slideshow> in                   // require it exists, else stop
            guard let existing else { return .fail(NotFoundError.slideshow(payload.id)) }
            return .next(existing)
        }
        .map(SlideshowReturn.init(from:))                           // project -> SlideshowReturn
        .effect { kernel, result in
            await kernel.buffer.mutate(SlideshowState.self) { $0.slideshow = result }
        }
        .seal()
}

package func openSlideshow(_ kernel: Kernel, _ payload: OpenSlideshowPayload) async throws {
    try await kernel.run(openSlideshowPipe(payload), payload.id)
}

/// Clear the open-slideshow slot, so no slideshow's slides (or their paths) stay
/// resident once nothing is open. Forward-only, no I/O — a plain buffer write.
package func closeSlideshow(_ kernel: Kernel, _ payload: CloseSlideshowPayload) async throws {
    await kernel.buffer.mutate(SlideshowState.self) { $0.slideshow = nil }
}

// MARK: - Shared publish

/// Reflect a freshly-saved full slideshow into both Stores: the path-free catalog
/// row in `LibraryState`, and the open-slideshow detail in `SlideshowState`
/// (only when that slot still holds the same slideshow — never clobber a different
/// one). Used by the `update` / `updateConfig` mutation pipelines.
func publishSlideshow(_ kernel: Kernel, _ result: SlideshowReturn) async {
    await kernel.buffer.mutate(LibraryState.self) { state in
        if let index = state.slideshows.firstIndex(where: { $0.id == result.id }) {
            state.slideshows[index] = SlideshowSummaryReturn(from: result)
        }
    }
    await kernel.buffer.mutate(SlideshowState.self) { state in
        if state.slideshow?.id == result.id { state.slideshow = result }
    }
}
