import Foundation

// MARK: - Payloads
//
// The input side of the Circuit ports — the argument to `kernel.call(Circuit.…)`.

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

