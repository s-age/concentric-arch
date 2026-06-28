import SwiftUI
import Kernel
import Contract
import Observation

/// Reads the global error channel from the buffer and clears it. The single
/// place Presentation observes `AppErrorState`, written by the kernel's error
/// sink when a dispatched command fails.
@Observable
@MainActor
package final class GlobalErrorViewModel {
    private let kernel: Kernel
    package init(kernel: Kernel) { self.kernel = kernel }

    var message: String? { kernel.buffer.read(AppErrorState.self).message }
    func dismiss() { kernel.buffer.mutate(AppErrorState.self) { $0.message = nil } }
}

package struct ContentView: View {
    @State private var library: SlideshowLibraryViewModel
    @State private var error: GlobalErrorViewModel
    @State private var selectedSlideshow: SlideshowReturn?
    @State private var spritePanel: SpritePanel?

    private let makeSlideshowPlayerViewModel: @MainActor @Sendable (SlideshowReturn) -> SlideshowPlayerViewModel
    private let makeSpritePlayerViewModel: @MainActor @Sendable (SlideshowReturn, Int) -> SlideshowPlayerViewModel

    package init(
        library: SlideshowLibraryViewModel,
        error: GlobalErrorViewModel,
        makeSlideshowPlayerViewModel: @escaping @MainActor @Sendable (SlideshowReturn) -> SlideshowPlayerViewModel,
        makeSpritePlayerViewModel: @escaping @MainActor @Sendable (SlideshowReturn, Int) -> SlideshowPlayerViewModel
    ) {
        _library = State(initialValue: library)
        _error = State(initialValue: error)
        self.makeSlideshowPlayerViewModel = makeSlideshowPlayerViewModel
        self.makeSpritePlayerViewModel = makeSpritePlayerViewModel
    }

    package var body: some View {
        Group {
            if let slideshow = selectedSlideshow {
                SlideshowPlayerView(
                    viewModel: makeSlideshowPlayerViewModel(slideshow),
                    onBack: { selectedSlideshow = nil },
                    onSpriteMode: { startIndex in openSpriteMode(slideshow: slideshow, startIndex: startIndex) }
                )
                .navigationTitle(slideshow.name)
            } else {
                HomeView(
                    viewModel: library,
                    onSlideshowSelected: { selectedSlideshow = $0 }
                )
                .navigationTitle("")
            }
        }
        .overlay(alignment: .top) {
            if let message = error.message {
                ErrorBanner(message: message, onDismiss: { error.dismiss() })
            }
        }
        .animation(.default, value: error.message)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let panel = notification.object as? SpritePanel, panel === spritePanel {
                spritePanel = nil
            }
        }
    }

    private func openSpriteMode(slideshow: SlideshowReturn, startIndex: Int) {
        spritePanel?.close()
        let viewModel = makeSpritePlayerViewModel(slideshow, startIndex)
        spritePanel = SpritePanel.open { panel in
            SlideshowPlayerView(
                viewModel: viewModel,
                onBack: { [weak panel] in panel?.close() }
            )
        }
        selectedSlideshow = nil
    }
}

/// The global error band pinned to the top of the window.
private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(.red, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
