import SwiftUI
import Contract

struct SlideshowPlayerView: View {
    let viewModel: SlideshowPlayerViewModel
    let onBack: () -> Void
    let onSpriteMode: ((SlideshowReturn, Int) -> Void)?

    init(
        viewModel: SlideshowPlayerViewModel,
        onBack: @escaping () -> Void,
        onSpriteMode: ((SlideshowReturn, Int) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onBack = onBack
        self.onSpriteMode = onSpriteMode
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .ignoresSafeArea()

            slideImage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(viewModel.currentIndex)
                .transition(slideTransition)

            if viewModel.showFilmstrip {
                FilmstripView(
                    slides: viewModel.displayedSlides,
                    currentIndex: viewModel.currentIndex,
                    duration: viewModel.slideshow.config.duration,
                    transition: viewModel.slideshow.config.transition,
                    onSelect: { index in Task { await viewModel.jumpTo(index: index) } },
                    onDurationChange: { duration in Task { await viewModel.updateDuration(duration) } },
                    onTransitionChange: { transition in Task { await viewModel.updateTransition(transition) } },
                    isPlaying: viewModel.isPlaying,
                    isShuffled: viewModel.isShuffled,
                    onPrevious: { Task { await viewModel.previous() } },
                    onPlayPause: {
                        if viewModel.isPlaying { viewModel.pause() } else { viewModel.play() }
                    },
                    onNext: { Task { await viewModel.userDidNext() } },
                    onToggleShuffle: { Task { await viewModel.toggleShuffle() } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onHover { hovering in
                    if hovering { viewModel.overlayHoverBegan() } else { viewModel.overlayHoverEnded() }
                }
            }

            if let hint = viewModel.fullscreenHint {
                fullscreenHintOverlay(hint)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if viewModel.showFilmstrip {
                HStack(spacing: 0) {
                    if let onSpriteMode {
                        Button {
                            onSpriteMode(viewModel.slideshow, viewModel.currentIndex)
                        } label: {
                            Image(systemName: "pip.enter")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(16)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                }
                .onHover { hovering in
                    if hovering { viewModel.overlayHoverBegan() } else { viewModel.overlayHoverEnded() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.currentIndex)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showFilmstrip)
        .animation(.easeInOut(duration: 0.5), value: viewModel.fullscreenHint)
        .focusable()
        .onKeyPress(.space) {
            if viewModel.isPlaying { viewModel.pause() } else { viewModel.play() }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            Task { await viewModel.previous() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            Task { await viewModel.userDidNext() }
            return .handled
        }
        .onTapGesture {
            viewModel.userDidInteract()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) {
                        if dx < -50 {
                            Task { await viewModel.userDidNext() }
                        } else if dx > 50 {
                            Task { await viewModel.previous() }
                        }
                    } else {
                        viewModel.userDidInteract()
                    }
                }
        )
        .onHover { hovering in
            if hovering { viewModel.userDidInteract() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            viewModel.windowDidEnterFullScreen()
        }
        .task { viewModel.requestOpen() }
        // Re-runs when the on-demand open lands (slide count 0 → N), and once on
        // appear for the value-seeded sprite: load the current image and autoplay.
        .task(id: viewModel.displayedSlides.count) {
            guard !viewModel.displayedSlides.isEmpty else { return }
            await viewModel.slidesDidBecomeAvailable()
        }
    }

    @ViewBuilder
    private func fullscreenHintOverlay(_ hint: SlideshowPlayerViewModel.FullscreenHintType) -> some View {
        let label: String = switch hint {
        case .enter: "Full Screen: Fn+F"
        case .exit: "Exit Full Screen: Esc"
        }
        let icon: String = switch hint {
        case .enter: "arrow.up.left.and.arrow.down.right"
        case .exit: "escape"
        }
        Label(label, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 16)
    }

    @ViewBuilder
    private var slideImage: some View {
        if let nsImage = viewModel.currentNSImage {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            Color.black
        }
    }

    private var slideTransition: AnyTransition {
        switch viewModel.slideshow.config.transition {
        case .none:
            return .identity
        case .fade, .dissolve:
            return .opacity
        case .slide:
            return .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            )
        }
    }
}
