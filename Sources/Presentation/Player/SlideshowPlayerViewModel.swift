import AppKit
import Foundation
import Kernel
import Contract
import Observation

@Observable
@MainActor
package final class SlideshowPlayerViewModel {
    /// Buffer-derived: the live slideshow comes from `LibraryState` (where every
    /// `Circuit.Slideshow` command publishes), so a forward-only `updateConfig`
    /// is reflected here via observation — no return value consumed. The seed is
    /// the value the player was opened with, used only as a fallback if the row
    /// is ever absent from the buffer.
    var slideshow: SlideshowReturn {
        kernel.buffer.read(LibraryState.self).slideshows.first { $0.id == seed.id } ?? seed
    }
    private let seed: SlideshowReturn
    private(set) var currentIndex: Int = 0
    private(set) var currentNSImage: NSImage?
    private(set) var isPlaying: Bool = false
    private(set) var isShuffled: Bool = false
    private var shuffledSlides: [SlideReturn]?

    var displayedSlides: [SlideReturn] {
        shuffledSlides ?? slideshow.slides
    }

    enum FullscreenHintType: Equatable {
        case enter
        case exit
    }

    let isSpriteMode: Bool

    private(set) var showFilmstrip: Bool = true
    private(set) var fullscreenHint: FullscreenHintType? = nil

    private let kernel: Kernel
    private let filmstripHideDuration: Duration
    private var timerTask: Task<Void, Never>?
    private var hideFilmstripTask: Task<Void, Never>?
    private var hideHintTask: Task<Void, Never>?
    private var overlayHoverCount: Int = 0
    private var enterHintShown: Bool = false

    package init(
        slideshow: SlideshowReturn,
        kernel: Kernel,
        filmstripHideDuration: Duration = .seconds(3),
        initialIndex: Int = 0,
        isSpriteMode: Bool = false
    ) {
        self.seed = slideshow
        self.kernel = kernel
        self.filmstripHideDuration = filmstripHideDuration
        self.currentIndex = initialIndex
        self.isSpriteMode = isSpriteMode
    }

    private var currentSlide: SlideReturn? {
        let slides = displayedSlides
        guard !slides.isEmpty, currentIndex < slides.count else { return nil }
        return slides[currentIndex]
    }

    // MARK: - Shuffle

    func toggleShuffle() async {
        if isShuffled {
            let currentID = currentSlide?.id
            isShuffled = false
            shuffledSlides = nil
            currentIndex = currentID.flatMap { id in
                slideshow.slides.firstIndex(where: { $0.id == id })
            } ?? 0
        } else {
            shuffledSlides = slideshow.slides.shuffled()
            isShuffled = true
            currentIndex = 0
        }
        await loadCurrentImage()
    }

    // MARK: - Playback

    func play() {
        guard !displayedSlides.isEmpty else { return }
        guard let duration = slideshow.config.duration.seconds else { return }
        isPlaying = true
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled, isPlaying {
                do {
                    try await Task.sleep(for: .seconds(duration))
                } catch {
                    break
                }
                guard !Task.isCancelled, isPlaying else { break }
                await next()
            }
        }
        if !enterHintShown, !isSpriteMode {
            enterHintShown = true
            showHint(.enter)
        }
        showFilmstripOverlay()
    }

    func pause() {
        isPlaying = false
        timerTask?.cancel()
        timerTask = nil
        hideFilmstripTask?.cancel()
        hideFilmstripTask = nil
        showFilmstrip = true
    }

    func next() async {
        // View-cursor navigation over `displayedSlides`: no business logic, so no
        // kernel round-trip. `nil` = no more slides (end reached without loop).
        let count = displayedSlides.count
        let nextIndex: Int?
        if count == 0 {
            nextIndex = nil
        } else if currentIndex < count - 1 {
            nextIndex = currentIndex + 1
        } else {
            nextIndex = slideshow.config.loop ? 0 : nil
        }
        if let nextIndex {
            currentIndex = nextIndex
            await loadCurrentImage()
        } else {
            pause()
        }
    }

    func previous() async {
        let count = displayedSlides.count
        let prevIndex: Int?
        if count == 0 {
            prevIndex = nil
        } else if currentIndex > 0 {
            prevIndex = currentIndex - 1
        } else {
            prevIndex = slideshow.config.loop ? count - 1 : nil
        }
        if let prevIndex {
            currentIndex = prevIndex
            await loadCurrentImage()
            showFilmstripOverlay()
        }
    }

    func jumpTo(index: Int) async {
        guard index >= 0, index < displayedSlides.count else { return }
        currentIndex = index
        await loadCurrentImage()
        showFilmstripOverlay()
    }

    func loadCurrentImage() async {
        guard let slide = currentSlide else {
            currentNSImage = nil
            return
        }
        let expectedIndex = currentIndex
        let path = slide.localIdentifier
        let image = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: URL(fileURLWithPath: path))
        }.value
        guard currentIndex == expectedIndex else { return }
        currentNSImage = image
    }

    // MARK: - Config mutation

    func updateDuration(_ duration: SlideDurationReturn) async {
        let request = UpdateSlideshowConfigPayload(
            slideshowID: slideshow.id,
            duration: duration,
            transition: slideshow.config.transition,
            loop: slideshow.config.loop
        )
        // Fire-and-forget: the pipeline replaces the row in `LibraryState`, which
        // the `slideshow` accessor reads back via observation; failures surface in
        // the global banner.
        kernel.dispatch(Circuit.Slideshow.updateConfig, request)
        if isPlaying { play() }
    }

    func updateTransition(_ transition: TransitionTypeReturn) async {
        let request = UpdateSlideshowConfigPayload(
            slideshowID: slideshow.id,
            duration: slideshow.config.duration,
            transition: transition,
            loop: slideshow.config.loop
        )
        // Fire-and-forget: see `updateDuration`.
        kernel.dispatch(Circuit.Slideshow.updateConfig, request)
    }

    // MARK: - Filmstrip visibility

    func userDidInteract() {
        showFilmstripOverlay()
    }

    func userDidNext() async {
        await next()
        showFilmstripOverlay()
    }

    func overlayHoverBegan() {
        overlayHoverCount += 1
        showFilmstrip = true
        hideFilmstripTask?.cancel()
        hideFilmstripTask = nil
    }

    func overlayHoverEnded() {
        overlayHoverCount = max(0, overlayHoverCount - 1)
        guard overlayHoverCount == 0, isPlaying else { return }
        scheduleHideFilmstrip()
    }

    func showFilmstripOverlay() {
        showFilmstrip = true
        hideFilmstripTask?.cancel()
        hideFilmstripTask = nil
        guard isPlaying, overlayHoverCount == 0 else { return }
        scheduleHideFilmstrip()
    }

    func windowDidEnterFullScreen() {
        showHint(.exit)
    }

    private func showHint(_ type: FullscreenHintType) {
        hideHintTask?.cancel()
        fullscreenHint = type
        hideHintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            fullscreenHint = nil
        }
    }

    private func scheduleHideFilmstrip() {
        hideFilmstripTask = Task {
            try? await Task.sleep(for: filmstripHideDuration)
            guard !Task.isCancelled else { return }
            showFilmstrip = false
        }
    }
}
