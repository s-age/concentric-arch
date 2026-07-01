import AppKit
import SwiftUI
import SwiftData
import Kernel
import Contract
import Infrastructure
import Circuit
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
            // `kernel.buffer` and Circuit writes into. Only *app* states are
            // listed — the kernel-owned ones (`KernelErrorState`, and in DEBUG
            // the monitor states) are seeded by `build()` itself.
            let bufferBuilder = BufferBuilder()
            bufferBuilder.allocate(LibraryState())
            bufferBuilder.allocate(SlideshowState())

            // Bind every device onto the bus via the Driver gateway, so a
            // call/dispatch for a symbol routes to its concrete handler. The stores
            // (runtime SwiftData deps) are passed in; pure Compute/Circuit devices
            // default inside the gateway (swappable by parameter).
            let builder = KernelBuilder()
            wireAllDrivers(
                into: builder,
                slideshowStore: makeSlideshowStore(modelContainer),
                config: makeConfigStore(modelContainer)
            )
            // The sinks are framework defaults: a dispatched command's failure
            // renders into `KernelErrorState` (the banner), traces record into
            // `TraceState` (caps tunable via `monitor: MonitorOptions(...)`).
            // Inject `onError`/`onTrace` here only for a custom shape.
            kernel = builder.build(
                buffer: bufferBuilder.build(),
                // State side of time-travel: which stores each command-boundary
                // snapshot captures (rendered for the monitor + typed image for
                // live-restore). App still owns the list — the kernel absorbs the
                // read/render/record mechanics and stays state-agnostic.
                // `TraceState`/`BufferHistoryState`/`TimeTravelState` are simply
                // not listed: the trace, the history, and the preview flag are not
                // part of the world we rewind.
                snapshotStates: [LibraryState.self, SlideshowState.self, KernelErrorState.self]
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
                timeTravel: TimeTravelViewModel(kernel: kernel),
                makeSlideshowPlayerViewModel: { summary in
                    // Seed with a slides-less shell; the player loads the full,
                    // path-bearing slideshow on demand via `SlideshowState`.
                    SlideshowPlayerViewModel(slideshow: SlideshowReturn(shellFrom: summary), kernel: kernel)
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
                Button("Toggle Wiring Graph") {
                    // Introspect the real Circuit pipes here (App is the composition
                    // root that can see Circuit) and inject the derived shape.
                    let pipelines = circuitWiringIntrospection().map { intro in
                        WiringPipeline(
                            key: intro.key,
                            title: intro.title,
                            input: intro.inputType,
                            stages: intro.stages.map(WiringStage.init(descriptor:)),
                            note: intro.note
                        )
                    }
                    WiringGraphWindow.toggle(pipelines: pipelines)
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
            }
            #endif
        }
    }
}
