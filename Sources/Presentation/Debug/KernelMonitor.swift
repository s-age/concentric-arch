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

    /// The recorded command-boundary buffer snapshots (state side of time-travel).
    var history: BufferHistoryState { kernel.buffer.read(BufferHistoryState.self) }

    /// The flow root that `entry` belongs to — walk the `parent` chain up until it
    /// runs out (nil parent) or leaves the window (parent evicted). Matches
    /// `TraceState.forest`'s root rule, so the span returned is the snapshot key.
    func rootSpan(for entry: TraceEntry) -> UUID {
        let bySpan = Dictionary(entries.map { ($0.span, $0) }, uniquingKeysWith: { a, _ in a })
        var current = entry
        while let parent = current.parent, let next = bySpan[parent] {
            current = next
        }
        return current.span
    }

    /// The buffer state captured for the command the selected `entry` belongs to,
    /// or `nil` if none was recorded (capture was off, or it was evicted).
    func snapshot(for entry: TraceEntry) -> BufferSnapshot? {
        history.snapshot(forRoot: rootSpan(for: entry))
    }

    func clear() { kernel.buffer.mutate(TraceState.self) { $0.clear() } }
}

/// Which lens the lower "Visualize" pane shows for the selected row.
private enum InspectorTab: String, CaseIterable, Identifiable {
    case payload = "Payload"
    case buffer = "Buffer"
    var id: String { rawValue }
}

/// Short, stable label for a flow root — the leading hex of its UUID. Two
/// concurrent flows show different tags, so the eye groups a tree at a glance.
private func rootTag(_ id: UUID) -> String { String(id.uuidString.prefix(6)) }

struct KernelMonitorView: View {
    @State private var viewModel: KernelMonitorViewModel
    /// Row selected in the trace table; the lower pane inspects it. Selecting a
    /// row is the time cursor: the Buffer tab shows the world as of its command.
    @State private var selection: TraceTree.ID?
    /// Which lens the lower pane shows for the selected row.
    @State private var inspectorTab: InspectorTab = .payload

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
                Toggle("inspection", isOn: Binding(
                    get: { Kernel.recordsInspection },
                    set: { Kernel.recordsInspection = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Capture invoke payloads and command-boundary buffer snapshots (off by default — feeds the Payload and Buffer tabs / time-travel)")
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
                inspector
                    .frame(minHeight: 80, idealHeight: 160)
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

    // Lower pane ("Visualize"): a lens on the selected row. Payload is per-invoke
    // (the row's input); Buffer is per-command (the world as of the row's flow
    // root) — selecting an older row time-travels the Buffer tab to that point.
    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Visualize", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch inspectorTab {
            case .payload: payloadDetail
            case .buffer: bufferDetail
            }
        }
    }

    // Payload tab: the selected entry's full input, wrapped and selectable (the
    // table column shows only a one-line preview).
    private var payloadDetail: some View {
        ScrollView {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(entry.symbol).font(.system(.callout, design: .monospaced)).bold()
                        Text(entry.verb.rawValue).foregroundStyle(color(for: entry.verb))
                        Text("#\(entry.id)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(entry.payload ?? "Capture is off — switch the “inspection” toggle on, then re-run, to show it here.")
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

    // Buffer tab: the domain state as of the selected row's command boundary —
    // the snapshot tagged with the row's flow root. This is the viewing side of
    // time-travel: scrub the trace table and the world here rewinds with it.
    private var bufferDetail: some View {
        ScrollView {
            if let entry = selectedEntry {
                if let snapshot = viewModel.snapshot(for: entry) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("flow \(rootTag(snapshot.root))").font(.system(.callout, design: .monospaced)).bold()
                            Text("#\(snapshot.id)").foregroundStyle(.secondary).monospacedDigit()
                            Text(traceTimeFormatter.string(from: snapshot.timestamp)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ForEach(snapshot.stores) { dump in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dump.name).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Text(dump.value)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No buffer snapshot for this flow — switch the “inspection” toggle on, then re-run, to capture state at each command (older snapshots may have scrolled out of the window).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            } else {
                Text("Select a row to inspect the buffer at its command")
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
