import Kernel
import Contract

/// Pipeline: `Compute.Slideshow.create ▶ Infrastructure.Slideshow.save ▶ buffer.append + open`
///
/// No re-read: `create` already holds the full new slideshow in flight, so it fills
/// the open slot by projecting that result directly — the same way `update`
/// publishes its slot (a projection of the in-flight entity, not a post-save
/// fetch). The editor suppresses its own redundant `open` for this id.
/// The pipeline as a value — split from execution so it can be introspected
/// without running (see Circuit `WiringIntrospection`). No payload capture: the
/// new slideshow flows in as the pipe's input.
package func createSlideshowPipe() -> Pipe<CreateSlideshowPayload, SlideshowReturn> {
    pipeline(Callable.Compute.Slideshow.create)             // CreateSlideshowPayload -> Slideshow
        .tap(Callable.Infrastructure.Slideshow.save)        // persist, keep the Slideshow flowing
        .map(SlideshowReturn.init(from:))                   // project -> SlideshowReturn
        .effect { kernel, created in                        // append the catalog row…
            await kernel.buffer.mutate(LibraryState.self) {
                $0.slideshows.append(SlideshowSummaryReturn(from: created))
            }
            // …and open it for the editor, so the right pane shows it (Presentation
            // sets `selectedID` to this id and suppresses its own redundant open).
            await kernel.buffer.mutate(SlideshowState.self) { $0.slideshow = created }
        }
        .seal()
}

package func createSlideshow(_ kernel: Kernel, _ payload: CreateSlideshowPayload) async throws {
    try await kernel.run(createSlideshowPipe(), payload)
}
