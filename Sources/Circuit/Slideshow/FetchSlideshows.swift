import Kernel
import Contract

/// Pipeline: `Infrastructure.Library.fetchSummaries ▶ project ▶ buffer.write(LibraryState)`
///
/// Loads the *catalog* — path-free summaries, never the slides — and commits it
/// into `LibraryState`, flipping `isLoading` around the fetch so Presentation
/// observes the loading and loaded states without ever writing the buffer itself.
/// The pipeline as a value — split from execution so it can be introspected
/// without running. No payload capture (input is `Void`).
package func fetchSlideshowsPipe() -> Pipe<Void, [SlideshowSummaryReturn]> {
    pipeline(Callable.Infrastructure.Library.fetchSummaries)       // Void -> [SlideshowSummary]
        .map(note: "project each summary → SlideshowSummaryReturn") { $0.map(SlideshowSummaryReturn.init(from:)) }
        .effect(note: "commit catalog to LibraryState, isLoading=false") { kernel, returns in
            // Authoritative full reload. This is the one writer NOT safe against
            // a mutation that lands during `fetchSummaries` above (a create during cold
            // load is lost; a delete during a warm reload is resurrected): the
            // snapshot was taken before the I/O. We accept it — the DB stays
            // correct and the buffer reconciles on the next reload — rather than
            // serialize every writer. Closing it would require a lock or a
            // version/CAS guard around this apply.
            await kernel.buffer.mutate(LibraryState.self) {
                $0.slideshows = returns
                $0.isLoading = false
            }
        }
        .seal()
}

package func fetchSlideshows(_ kernel: Kernel, _ payload: FetchSlideshowsPayload) async throws {
    await kernel.buffer.mutate(LibraryState.self) { $0.isLoading = true }
    try await kernel.run(fetchSlideshowsPipe(), ())
}
