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

/// A trace entry placed in its call tree: how deep under its flow root it sits,
/// and which root it belongs to. Derived per-read from the flat `span`/`parent`
/// links so concurrent flows separate into distinct roots and nesting shows as
/// depth.
struct TraceRow: Identifiable {
    let entry: TraceEntry
    let depth: Int
    let root: UUID
    var id: Int { entry.id }
}

@Observable
@MainActor
final class KernelMonitorViewModel {
    private let kernel: Kernel
    init(kernel: Kernel) { self.kernel = kernel }

    var entries: [TraceEntry] { kernel.buffer.read(TraceState.self).entries }

    /// Each entry with its tree depth and flow root, rebuilt by walking the
    /// `span → parent` links. Ancestors evicted from the bounded ring just stop
    /// the walk early (the node reads as its own shallow root) — no crash, no
    /// unbounded loop (guarded).
    var rows: [TraceRow] {
        let entries = self.entries
        let parentOf: [UUID: UUID?] = Dictionary(
            entries.map { ($0.span, $0.parent) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries.map { entry in
            var depth = 0
            var root = entry.span
            var cursor = entry.parent
            var guardCount = 0
            while let span = cursor, guardCount < 256 {
                depth += 1
                root = span
                cursor = parentOf[span] ?? nil
                guardCount += 1
            }
            return TraceRow(entry: entry, depth: depth, root: root)
        }
    }

    func clear() { kernel.buffer.mutate(TraceState.self) { $0.clear() } }
}

/// Short, stable label for a flow root — the leading hex of its UUID. Two
/// concurrent flows show different tags, so the eye groups a tree at a glance.
private func rootTag(_ id: UUID) -> String { String(id.uuidString.prefix(6)) }

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
                Toggle("payload", isOn: Binding(
                    get: { Kernel.recordsPayload },
                    set: { Kernel.recordsPayload = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Capture each invoke's input payload (off by default — adds a String(describing:) per call)")
                Text("\(viewModel.entries.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Clear") { viewModel.clear() }
            }
            .padding(8)
            Divider()
            Table(Array(viewModel.rows.reversed())) { // newest first
                TableColumn("#") { Text("\($0.entry.id)").monospacedDigit() }
                    .width(48)
                TableColumn("time") { Text(traceTimeFormatter.string(from: $0.entry.timestamp)).monospacedDigit() }
                    .width(96)
                TableColumn("flow") { Text(rootTag($0.root)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                    .width(64)
                TableColumn("symbol") { row in
                    Text(row.entry.symbol)
                        .font(.system(.body, design: .monospaced))
                        .padding(.leading, CGFloat(row.depth) * 14)
                }
                TableColumn("verb") { Text($0.entry.verb.rawValue).foregroundStyle(color(for: $0.entry.verb)) }
                    .width(64)
                TableColumn("payload") { row in
                    Text(row.entry.payload ?? "—")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(row.entry.payload == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.entry.payload ?? "")
                }
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
