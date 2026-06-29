import Foundation

// MARK: - Payloads
//
// The input side of the ports — the argument to `kernel.call(…)`. Circuit ports
// take the request-shaped payloads below; Compute ports additionally take the
// transform payloads at the end, which bundle the current entity with the change.

// MARK: Slideshow

package struct CreateSlideshowPayload {
    /// Caller-supplied identity. Presentation mints the id, so it knows "which one
    /// to open" without consuming a return value or a buffer channel.
    package let id: UUID
    package let name: String
    package let localIdentifiers: [String]
    package let duration: SlideDurationReturn
    package let transition: TransitionTypeReturn
    package let loop: Bool

    package init(id: UUID, name: String, localIdentifiers: [String], duration: SlideDurationReturn, transition: TransitionTypeReturn, loop: Bool) {
        self.id = id
        self.name = name
        self.localIdentifiers = localIdentifiers
        self.duration = duration
        self.transition = transition
        self.loop = loop
    }
}

package struct UpdateSlideshowPayload {
    package let id: UUID
    package let name: String
    package let localIdentifiers: [String]

    package init(id: UUID, name: String, localIdentifiers: [String]) {
        self.id = id
        self.name = name
        self.localIdentifiers = localIdentifiers
    }
}

package struct UpdateSlideshowConfigPayload {
    package let slideshowID: UUID
    package let duration: SlideDurationReturn
    package let transition: TransitionTypeReturn
    package let loop: Bool

    package init(slideshowID: UUID, duration: SlideDurationReturn, transition: TransitionTypeReturn, loop: Bool) {
        self.slideshowID = slideshowID
        self.duration = duration
        self.transition = transition
        self.loop = loop
    }
}

package struct FetchSlideshowsPayload {
    package init() {}
}

package struct DeleteSlideshowPayload {
    package let id: UUID

    package init(id: UUID) {
        self.id = id
    }
}

// MARK: Config

package struct SaveConfigPayload {
    package let duration: SlideDurationReturn
    package let transition: TransitionTypeReturn
    package let loop: Bool

    package init(duration: SlideDurationReturn, transition: TransitionTypeReturn, loop: Bool) {
        self.duration = duration
        self.transition = transition
        self.loop = loop
    }
}

// MARK: Image

package struct AddDroppedFilesPayload {
    package let urls: [URL]
    package let existingIdentifiers: [String]

    package init(urls: [URL], existingIdentifiers: [String]) {
        self.urls = urls
        self.existingIdentifiers = existingIdentifiers
    }
}

// MARK: Compute transforms
//
// Transform ops bundle the current `Slideshow` entity with the requested change,
// since Compute is stateless and receives everything it needs as data.

package struct UpdateSlideshowComputePayload {
    package let current: Slideshow
    package let name: String
    package let localIdentifiers: [String]

    package init(current: Slideshow, name: String, localIdentifiers: [String]) {
        self.current = current
        self.name = name
        self.localIdentifiers = localIdentifiers
    }
}

package struct ApplyConfigComputePayload {
    package let current: Slideshow
    package let duration: SlideDurationReturn
    package let transition: TransitionTypeReturn
    package let loop: Bool

    package init(current: Slideshow, duration: SlideDurationReturn, transition: TransitionTypeReturn, loop: Bool) {
        self.current = current
        self.duration = duration
        self.transition = transition
        self.loop = loop
    }
}

