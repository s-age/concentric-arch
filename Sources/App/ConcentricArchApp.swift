import AppKit
import SwiftUI
import SwiftData
import Kernel
import Contract
import Infrastructure
import Driver
import Presentation

/// Promotes the process to a foreground GUI app at launch.
///
/// Running the SwiftPM executable directly (e.g. Xcode's Run, or `swift run`)
/// produces an *unbundled* process with no Info.plist, so AppKit leaves it as a
/// background tool and the window never appears. Forcing `.regular` activation
/// makes the window show. Harmless in the bundled `.app` (already `.regular`) —
/// the real distribution path is `Scripts/build.sh`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ConcentricArchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer
    private let kernel: Kernel

    init() {
        do {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else {
                fatalError("Application Support directory is unavailable")
            }
            // Namespace all persistence under an app-specific directory. Without an explicit
            // store URL, SwiftData defaults to the shared `Application Support/default.store`,
            // which a non-sandboxed build would share with any other app on the machine
            // (e.g. the original 10slide app). Pin the store to concentric-arch's own directory.
            let appDirectory = appSupport.appendingPathComponent("concentric-arch", isDirectory: true)
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            // The SwiftData schema lives behind a factory in Infrastructure; the
            // @Model types stay internal to that module.
            modelContainer = try makeModelContainer(
                url: appDirectory.appendingPathComponent("concentric-arch.store")
            )

            // Allocate the named containers of the typed, observable state region.
            // App owns this "provide the vessels" role: each `allocate` seeds one
            // Store, keyed by its state type, that Presentation later reads via
            // `kernel.buffer` and Circuit writes into.
            let bufferBuilder = BufferBuilder()
            bufferBuilder.allocate(LibraryState())
            bufferBuilder.allocate(AppErrorState())
            #if DEBUG
            bufferBuilder.allocate(TraceState())
            #endif

            // Wire the Driver(port + repository) into the kernel so that
            // `kernel.call(Infrastructure.Library.<method>, payload)` dispatches
            // through LibraryDriver to the repository.
            let builder = KernelBuilder()
            // Infrastructure ports (leaf handlers → repositories/stores).
            LibraryDriver(repository: makeSlideshowStore(modelContainer)).wire(into: builder)
            InfrastructureConfigDriver(store: makeConfigStore(modelContainer)).wire(into: builder)
            // Compute device (leaf handlers → pure domain logic).
            SlideshowComputeDriver().wire(into: builder)
            ImageComputeDriver().wire(into: builder)
            // Circuit device (composing handlers → orchestration that routes via the kernel).
            SlideshowDriver().wire(into: builder)
            CircuitConfigDriver().wire(into: builder)
            // The kernel routes a dispatched command's failure here; App owns the
            // concrete error-state type, so it writes the buffer on the kernel's behalf.
            let buffer = bufferBuilder.build()
            kernel = builder.build(
                buffer: buffer,
                onError: { error in
                    await buffer.mutate(AppErrorState.self) { $0.message = error.localizedDescription }
                },
                onTrace: { symbol, verb, span, parent, payload, at in
                    #if DEBUG
                    await buffer.mutate(TraceState.self) {
                        $0.record(symbol: symbol, verb: verb, span: span, parent: parent, payload: payload, at: at, cap: 300)
                    }
                    #endif
                }
            )
        } catch {
            fatalError("Initialization failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                library: SlideshowLibraryViewModel(kernel: kernel),
                error: GlobalErrorViewModel(kernel: kernel),
                makeSlideshowPlayerViewModel: { slideshow in
                    SlideshowPlayerViewModel(slideshow: slideshow, kernel: kernel)
                },
                makeSpritePlayerViewModel: { slideshow, initialIndex in
                    SlideshowPlayerViewModel(
                        slideshow: slideshow,
                        kernel: kernel,
                        initialIndex: initialIndex,
                        isSpriteMode: true
                    )
                }
            )
        }
        .modelContainer(modelContainer)
        .commands {
            #if DEBUG
            CommandMenu("Debug") {
                Button("Toggle Kernel Monitor") {
                    KernelMonitorWindow.toggle(kernel: kernel)
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }
            #endif
        }
    }
}
