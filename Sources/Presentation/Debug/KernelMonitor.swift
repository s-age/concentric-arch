#if DEBUG
import AppKit
import SwiftUI
import Kernel

/// Live view of the kernel's invocation trace (`TraceState` in the buffer).
///
/// DEBUG only: the whole file compiles out of release, and `TraceState` is only
/// allocated in debug builds. Mirrors the read-only/observable contract — the
/// view model only reads the buffer (and clears it); the entries are written by
/// the kernel's trace sink on every `invoke`.

private let traceTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

@Observable
@MainActor
final class KernelMonitorViewModel {
    private let kernel: Kernel
    init(kernel: Kernel) { self.kernel = kernel }

    var entries: [TraceEntry] { kernel.buffer.read(TraceState.self).entries }
    func clear() { kernel.buffer.mutate(TraceState.self) { $0.clear() } }
}

struct KernelMonitorView: View {
    @State private var viewModel: KernelMonitorViewModel

    init(viewModel: KernelMonitorViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Kernel Monitor").font(.headline)
                Spacer()
                Text("\(viewModel.entries.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Clear") { viewModel.clear() }
            }
            .padding(8)
            Divider()
            Table(Array(viewModel.entries.reversed())) { // newest first
                TableColumn("#") { Text("\($0.id)").monospacedDigit() }
                    .width(48)
                TableColumn("time") { Text(traceTimeFormatter.string(from: $0.timestamp)).monospacedDigit() }
                    .width(96)
                TableColumn("symbol") { Text($0.symbol).font(.system(.body, design: .monospaced)) }
                TableColumn("verb") { Text($0.verb.rawValue).foregroundStyle(color(for: $0.verb)) }
                    .width(64)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private func color(for verb: TraceVerb) -> Color {
        switch verb {
        case .next: .secondary
        case .abort: .blue
        case .divert: .orange
        case .fail: .red
        }
    }
}

private final class MonitorPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Kernel Monitor"
        isFloatingPanel = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}

/// Opens/closes the monitor as a single floating panel. App wires a Debug menu
/// command to `toggle`.
@MainActor
package enum KernelMonitorWindow {
    private static var panel: NSPanel?

    package static func toggle(kernel: Kernel) {
        if let panel {
            panel.close()
            Self.panel = nil
            return
        }
        let panel = MonitorPanel()
        panel.contentView = NSHostingView(
            rootView: KernelMonitorView(viewModel: KernelMonitorViewModel(kernel: kernel))
        )
        panel.center()
        panel.orderFront(nil)
        Self.panel = panel
    }
}
#endif
