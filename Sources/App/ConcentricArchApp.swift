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

#if DEBUG
/// Multi-line, indented reflection of a value for the monitor's Buffer tab.
/// `dump` walks the value with `Mirror`, so it needs no `Codable`/`CustomString`
/// conformance — it pretty-prints any app state as-is, which is why the
/// snapshot sink keeps strings (rendered here) rather than typed values.
private func prettyDump(_ value: Any) -> String {
    var text = ""
    dump(value, to: &text)
    return text
}
#endif

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
            bufferBuilder.allocate(SlideshowState())
            bufferBuilder.allocate(AppErrorState())
            #if DEBUG
            bufferBuilder.allocate(TraceState())
            bufferBuilder.allocate(BufferHistoryState())
            bufferBuilder.allocate(TimeTravelState())
            #endif

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
            // The kernel routes a dispatched command's failure here; App owns the
            // concrete error-state type, so it writes the buffer on the kernel's behalf.
            let buffer = bufferBuilder.build()
            kernel = builder.build(
                buffer: buffer,
                onError: { error, symbol in
                    await buffer.mutate(AppErrorState.self) { $0.message = "\(symbol): \(error.localizedDescription)" }
                },
                onTrace: { symbol, verb, span, parent, payload, at in
                    #if DEBUG
                    await buffer.mutate(TraceState.self) {
                        $0.record(symbol: symbol, verb: verb, span: span, parent: parent, payload: payload, at: at, cap: 300)
                    }
                    #endif
                },
                // State side of time-travel: at each command boundary (flow root)
                // render the app-state stores to text and append to the snapshot ring.
                // App owns the store list — the kernel stays state-agnostic, exactly
                // as it does for the error and trace sinks. `TraceState`/
                // `BufferHistoryState` are deliberately excluded (the trace and the
                // history are not part of the world we rewind).
                onSnapshot: { root, at in
                    #if DEBUG
                    // One main-actor hop: read the app-state stores, render them for
                    // display *and* keep an erased typed copy for live-restore. Both
                    // are built here so the non-Sendable `image` never leaves the
                    // main actor. `TraceState`/`BufferHistoryState`/`TimeTravelState`
                    // are excluded — the trace, the history, and the preview flag are
                    // not part of the world we rewind.
                    await MainActor.run {
                        let library = buffer.read(LibraryState.self)
                        let openSlideshow = buffer.read(SlideshowState.self)
                        let appError = buffer.read(AppErrorState.self)
                        let dumps = [
                            StoreDump(name: "\(LibraryState.self)", value: prettyDump(library)),
                            StoreDump(name: "\(SlideshowState.self)", value: prettyDump(openSlideshow)),
                            StoreDump(name: "\(AppErrorState.self)", value: prettyDump(appError)),
                        ]
                        let image: BufferImage = [
                            ObjectIdentifier(LibraryState.self): library,
                            ObjectIdentifier(SlideshowState.self): openSlideshow,
                            ObjectIdentifier(AppErrorState.self): appError,
                        ]
                        buffer.mutate(BufferHistoryState.self) {
                            $0.record(root: root, stores: dumps, image: image, at: at, cap: 100)
                        }
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
