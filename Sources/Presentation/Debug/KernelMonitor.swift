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

    /// The flat trace rebuilt into a forest of call trees (see `TraceState.forest`):
    /// each flow is one contiguous, foldable tree, so concurrent flows no longer
    /// interleave row-by-row.
    var forest: [TraceTree] { kernel.buffer.read(TraceState.self).forest }

    func clear() { kernel.buffer.mutate(TraceState.self) { $0.clear() } }
}

/// Short, stable label for a flow root — the leading hex of its UUID. Two
/// concurrent flows show different tags, so the eye groups a tree at a glance.
private func rootTag(_ id: UUID) -> String { String(id.uuidString.prefix(6)) }

struct KernelMonitorView: View {
    @State private var viewModel: KernelMonitorViewModel
    /// Row selected in the trace table; its full payload shows in the lower pane.
    @State private var selection: TraceTree.ID?

    init(viewModel: KernelMonitorViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    /// The entry behind the selected row (looked up flat by id — the table id is
    /// `entry.id`), or `nil` when nothing is selected.
    private var selectedEntry: TraceEntry? {
        guard let selection else { return nil }
        return viewModel.entries.first { $0.id == selection }
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
            // Split the window ~8:2 (draggable): the call-tree table on top, the
            // selected row's full payload on the bottom — the table's payload
            // column truncates to one line, so the lower pane is where you read it.
            VSplitView {
                traceTable
                    .frame(minHeight: 160)
                payloadDetail
                    .frame(minHeight: 56, idealHeight: 120)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    // Hierarchical Table: `children` drives the disclosure outline, so the call
    // tree indents in the leading (symbol) column and each flow folds
    // independently. Expansion and selection are keyed by the stable `entry.id`.
    private var traceTable: some View {
        Table(viewModel.forest, children: \.children, selection: $selection) {
            TableColumn("symbol") { (node: TraceTree) in
                Text(node.entry.symbol).font(.system(.body, design: .monospaced))
            }
            TableColumn("#") { (node: TraceTree) in Text("\(node.entry.id)").monospacedDigit() }
                .width(48)
            TableColumn("time") { (node: TraceTree) in Text(traceTimeFormatter.string(from: node.entry.timestamp)).monospacedDigit() }
                .width(96)
            TableColumn("flow") { (node: TraceTree) in Text(rootTag(node.root)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                .width(64)
            TableColumn("verb") { (node: TraceTree) in Text(node.entry.verb.rawValue).foregroundStyle(color(for: node.entry.verb)) }
                .width(64)
            TableColumn("payload") { (node: TraceTree) in
                Text(node.entry.payload ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(node.entry.payload == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // Lower pane: the selected entry's full payload, wrapped and selectable
    // (the table column shows only a one-line preview).
    private var payloadDetail: some View {
        ScrollView {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(entry.symbol).font(.system(.callout, design: .monospaced)).bold()
                        Text(entry.verb.rawValue).foregroundStyle(color(for: entry.verb))
                        Text("#\(entry.id)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(entry.payload ?? "Payload capture is off — switch the “payload” toggle on, then re-run, to show it here.")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(entry.payload == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a row to inspect its payload")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
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
