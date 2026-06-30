#if DEBUG
import struct Foundation.UUID
import Kernel
import Contract

/// One Circuit pipeline's static shape, read back from its *real* `Pipe` value via
/// the L1 stage descriptors — no execution, no hand-authoring. App maps this into
/// the Presentation wiring-graph model (Presentation does not depend on Circuit).
package struct CircuitPipeIntrospection: Sendable {
    package let key: String          // the dispatch key the pipe backs
    package let title: String        // the saga function name
    package let inputType: String    // the type entering the pipe
    package let stages: [StageDescriptor]
    package let note: String?        // out-of-pipe context the static shape can't show

    package init(key: String, title: String, inputType: String, stages: [StageDescriptor], note: String?) {
        self.key = key
        self.title = title
        self.inputType = inputType
        self.stages = stages
        self.note = note
    }
}

/// Read every Circuit pipeline's shape from its real `Pipe` value. The
/// payload-capturing pipelines are built with throwaway payloads — only the
/// *structure* (`Pipe.descriptors`) is read; the dummy values are never inspected
/// and the pipe is never run. The dummies are compile-checked against the real
/// payload initializers, so this can't silently drift from the pipelines.
package func circuitWiringIntrospection() -> [CircuitPipeIntrospection] {
    func entry<I, O>(_ key: String, _ title: String, _ pipe: Pipe<I, O>, note: String? = nil) -> CircuitPipeIntrospection {
        CircuitPipeIntrospection(key: key, title: title, inputType: pipe.inputType, stages: pipe.descriptors, note: note)
    }

    let probeID = UUID()
    return [
        entry("Circuit.Slideshow.create", "createSlideshow", createSlideshowPipe()),
        entry(
            "Circuit.Slideshow.update", "updateSlideshow",
            updateSlideshowPipe(UpdateSlideshowPayload(id: probeID, name: "", localIdentifiers: nil)),
            note: "Dispatch payload UpdateSlideshowPayload; payload.id enters the pipe."
        ),
        entry(
            "Circuit.Slideshow.updateConfig", "updateSlideshowConfig",
            updateSlideshowConfigPipe(UpdateSlideshowConfigPayload(
                slideshowID: probeID,
                duration: SlideDurationReturn.allCases.first!,
                transition: TransitionTypeReturn.allCases.first!,
                loop: false
            )),
            note: "Dispatch payload UpdateSlideshowConfigPayload; payload.slideshowID enters the pipe."
        ),
        entry(
            "Circuit.Slideshow.open", "openSlideshow",
            openSlideshowPipe(OpenSlideshowPayload(id: probeID))
        ),
        entry(
            "Circuit.Slideshow.delete", "deleteSlideshow",
            deleteSlideshowPipe(DeleteSlideshowPayload(id: probeID))
        ),
        entry(
            "Circuit.Library.fetchAll", "fetchSlideshows", fetchSlideshowsPipe(),
            note: "Pre-pipe: sets LibraryState.isLoading=true outside kernel.run (not a stage)."
        ),
        entry(
            "Circuit.Config.save", "saveConfig", saveConfigPipe(),
            note: "Pre-pipe: builds SlideshowConfig from SaveConfigPayload outside kernel.run (not a stage)."
        ),
        // closeSlideshow has no pipe — a direct buffer write. Recorded with no
        // stages so the catalog stays complete without inventing structure.
        CircuitPipeIntrospection(
            key: "Circuit.Slideshow.close", title: "closeSlideshow",
            inputType: "CloseSlideshowPayload", stages: [],
            note: "No pipe: a direct buffer write (no kernel.run)."
        ),
    ]
}
#endif
