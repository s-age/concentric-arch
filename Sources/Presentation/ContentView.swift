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

/// Drives the DEBUG time-travel preview from the main window: reports whether a
/// past snapshot is currently reflected into the live buffer, and exits back to
/// the present. In release the preview state is never allocated, so this reads
/// nothing and always reports "live" — the banner and freeze compile away to
/// no-ops.
@Observable
@MainActor
package final class TimeTravelViewModel {
    private let kernel: Kernel
    package init(kernel: Kernel) { self.kernel = kernel }

    package var isPreviewing: Bool {
        #if DEBUG
        kernel.buffer.read(TimeTravelState.self).previewRoot != nil
        #else
        false
        #endif
    }

    /// Short hex tag of the previewed flow root, mirroring the monitor's label.
    package var previewTag: String? {
        #if DEBUG
        kernel.buffer.read(TimeTravelState.self).previewRoot.map { String($0.uuidString.prefix(6)) }
        #else
        nil
        #endif
    }

    package func exit() {
        #if DEBUG
        kernel.exitTimeTravel()
        #endif
    }
}

package struct ContentView: View {
    @State private var library: SlideshowLibraryViewModel
    @State private var error: GlobalErrorViewModel
    @State private var timeTravel: TimeTravelViewModel
    @State private var selectedSlideshow: SlideshowReturn?
    @State private var spritePanel: SpritePanel?

    private let makeSlideshowPlayerViewModel: @MainActor @Sendable (SlideshowReturn) -> SlideshowPlayerViewModel
    private let makeSpritePlayerViewModel: @MainActor @Sendable (SlideshowReturn, Int) -> SlideshowPlayerViewModel

    package init(
        library: SlideshowLibraryViewModel,
        error: GlobalErrorViewModel,
        timeTravel: TimeTravelViewModel,
        makeSlideshowPlayerViewModel: @escaping @MainActor @Sendable (SlideshowReturn) -> SlideshowPlayerViewModel,
        makeSpritePlayerViewModel: @escaping @MainActor @Sendable (SlideshowReturn, Int) -> SlideshowPlayerViewModel
    ) {
        _library = State(initialValue: library)
        _error = State(initialValue: error)
        _timeTravel = State(initialValue: timeTravel)
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
        // Freeze the live app while a past snapshot is reflected into the buffer:
        // the content goes inert, and a banner (added *after* `.disabled`, so it
        // stays live) is the only way back to the present.
        .disabled(timeTravel.isPreviewing)
        .overlay(alignment: .top) {
            if timeTravel.isPreviewing {
                TimeTravelBanner(tag: timeTravel.previewTag, onReturn: { timeTravel.exit() })
            }
        }
        .animation(.default, value: error.message)
        .animation(.default, value: timeTravel.isPreviewing)
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

/// The time-travel band: pinned to the top while the app shows a past snapshot,
/// it names the previewed flow and is the only live control until you return to
/// the present.
private struct TimeTravelBanner: View {
    let tag: String?
    let onReturn: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
            Text(tag.map { "Time-travel preview — flow \($0)" } ?? "Time-travel preview")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Return to present", action: onReturn)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(.indigo, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
