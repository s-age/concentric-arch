#if DEBUG
import struct Foundation.UUID
import Kernel
import Contract

/// Read every Circuit pipeline's shape from its real `Pipe` value into the
/// kernel's canonical carrier (`PipeDescriptor`) — no execution, no
/// hand-authoring, no re-encoding. App passes the list straight to the wiring
/// graph (App is the only ring that can see both Circuit and the tooling).
///
/// The payload-capturing pipelines are built with throwaway payloads — only the
/// *structure* (`Pipe.descriptors`) is read; the dummy values are never inspected
/// and the pipe is never run. The dummies are compile-checked against the real
/// payload initializers, so this can't silently drift from the pipelines.
package func circuitWiringIntrospection() -> [PipeDescriptor] {
    let probeID = UUID()
    return [
        PipeDescriptor(
            key: "Circuit.Slideshow.create", title: "createSlideshow",
            pipe: createSlideshowPipe()
        ),
        PipeDescriptor(
            key: "Circuit.Slideshow.update", title: "updateSlideshow",
            pipe: updateSlideshowPipe(UpdateSlideshowPayload(id: probeID, name: "", localIdentifiers: nil)),
            note: "Dispatch payload UpdateSlideshowPayload; payload.id enters the pipe."
        ),
        PipeDescriptor(
            key: "Circuit.Slideshow.updateConfig", title: "updateSlideshowConfig",
            pipe: updateSlideshowConfigPipe(UpdateSlideshowConfigPayload(
                slideshowID: probeID,
                duration: SlideDurationReturn.allCases.first!,
                transition: TransitionTypeReturn.allCases.first!,
                loop: false
            )),
            note: "Dispatch payload UpdateSlideshowConfigPayload; payload.slideshowID enters the pipe."
        ),
        PipeDescriptor(
            key: "Circuit.Slideshow.open", title: "openSlideshow",
            pipe: openSlideshowPipe(OpenSlideshowPayload(id: probeID))
        ),
        PipeDescriptor(
            key: "Circuit.Slideshow.delete", title: "deleteSlideshow",
            pipe: deleteSlideshowPipe(DeleteSlideshowPayload(id: probeID))
        ),
        PipeDescriptor(
            key: "Circuit.Library.fetchAll", title: "fetchSlideshows",
            pipe: fetchSlideshowsPipe(),
            note: "Pre-pipe: sets LibraryState.isLoading=true outside kernel.run (not a stage)."
        ),
        PipeDescriptor(
            key: "Circuit.Config.save", title: "saveConfig",
            pipe: saveConfigPipe(),
            note: "Pre-pipe: builds SlideshowConfig from SaveConfigPayload outside kernel.run (not a stage)."
        ),
        // closeSlideshow has no pipe — a direct buffer write. Recorded with no
        // stages so the catalog stays complete without inventing structure.
        PipeDescriptor(
            key: "Circuit.Slideshow.close", title: "closeSlideshow",
            inputType: "CloseSlideshowPayload", stages: [],
            note: "No pipe: a direct buffer write (no kernel.run)."
        ),
    ]
}
#endif
