#if DEBUG
import AppKit
import SwiftUI

/// A node-analysis view of the Circuit pipelines — opened from the Debug menu,
/// separate from the `KernelMonitor`. Where the monitor shows the *runtime* trace,
/// this shows the *shape*: each Circuit file expanded into its pipe stages.
///
/// Layout is master-detail: a fixed-width Circuit list on the left, the selected
/// pipeline's node flow (top-to-bottom) on the right, and a node-inspector below
/// the canvas. The downward flow keeps reading low-effort — no horizontal scrub.
///
/// First step on purpose: the graph is **hand-authored** in `WiringCatalog` below,
/// not derived by static introspection. `Pipe` is still an opaque closure array
/// (`Pipe.swift`), so until `PipeStage` carries a descriptor, the topology cannot be
/// read back from the real pipelines. This view proves the visualization against a
/// data model that the eventual L1-derived source can drop straight into — the only
/// thing that changes later is who fills `WiringCatalog`.
///
/// The model is deliberately the honest subset L1 will be able to see: pipe stages
/// only. Pre-/post-pipe work that lives outside `kernel.run` (a bare `buffer.mutate`,
/// a payload `build`) is recorded as a pipeline `note`, not a node, so the picture
/// never promises more than the future automatic source can deliver.

// MARK: - Model

/// The builder method that minted a stage — its role in the pipe. Mirrors the
/// `PipeBuilder` surface in `Pipe.swift`; `verb`/`map`/`effect` are anonymous
/// (no symbol), the rest name the symbol they invoke.
enum StageKind: String {
    case pipe          // .pipe(symbol)               — invoke, its verb drives the pipe
    case pipeAdapt     // .pipe(symbol) { adapt }      — build the next payload, then invoke
    case verb          // .pipe { -> Verb }            — anonymous self-describing stage (a guard)
    case tap           // .tap(symbol)                 — side-effect, the value flows through
    case map           // .map(transform)              — pure projection
    case effect        // .effect { ... }              — effectful passthrough (a buffer write)
}

/// One node: a single pipe stage. `symbol` is the dotted id it invokes
/// (`Layer.Device.method`) or `nil` for an anonymous stage. `flows` is the type
/// leaving this stage — the label on the outgoing `.next` wire. `branches` lists
/// the non-`.next` verbs this stage can emit (`.fail`/`.abort`/`.divert`), shown
/// as badges rather than drawn as edges, since their targets aren't static.
struct WiringStage {
    let kind: StageKind
    let symbol: String?
    let flows: String
    let note: String?
    var branches: [String] = []
}

/// One Circuit file expanded: the dispatch key it backs, the payload that enters
/// the pipe, and the ordered stages. `note` carries out-of-pipe context (work that
/// happens around `kernel.run` and so would be invisible to the static source).
struct WiringPipeline {
    let key: String        // the dispatch key the pipe backs, e.g. "Circuit.Slideshow.update"
    let title: String      // the saga function, e.g. "updateSlideshow"
    let input: String      // the type fed into the pipe
    let stages: [WiringStage]
    var note: String? = nil

    var branchCount: Int { stages.reduce(0) { $0 + $1.branches.count } }
}

// MARK: - Hand-authored catalog (the L1-derived source replaces this later)

enum WiringCatalog {
    static let pipelines: [WiringPipeline] = [
        WiringPipeline(
            key: "Circuit.Slideshow.create",
            title: "createSlideshow",
            input: "CreateSlideshowPayload",
            stages: [
                WiringStage(kind: .pipe, symbol: "Compute.Slideshow.create", flows: "Slideshow", note: "build the new slideshow"),
                WiringStage(kind: .tap, symbol: "Infrastructure.Slideshow.save", flows: "Slideshow", note: "persist, keep flowing"),
                WiringStage(kind: .map, symbol: nil, flows: "SlideshowReturn", note: "SlideshowReturn.init"),
                WiringStage(kind: .effect, symbol: nil, flows: "SlideshowReturn", note: "append catalog row + open detail"),
            ]
        ),
        WiringPipeline(
            key: "Circuit.Slideshow.update",
            title: "updateSlideshow",
            input: "UUID",
            stages: [
                WiringStage(kind: .pipe, symbol: "Infrastructure.Slideshow.fetch", flows: "Slideshow?", note: "load current"),
                WiringStage(kind: .verb, symbol: nil, flows: "Slideshow", note: "require it exists", branches: ["✕ fail: NotFound"]),
                WiringStage(kind: .pipeAdapt, symbol: "Compute.Slideshow.update", flows: "Slideshow", note: "adapt → UpdateSlideshowComputePayload"),
                WiringStage(kind: .tap, symbol: "Infrastructure.Slideshow.save", flows: "Slideshow", note: "persist, keep flowing"),
                WiringStage(kind: .map, symbol: nil, flows: "SlideshowReturn", note: "SlideshowReturn.init"),
                WiringStage(kind: .effect, symbol: nil, flows: "SlideshowReturn", note: "publishSlideshow"),
            ],
            note: "Dispatch payload UpdateSlideshowPayload; only payload.id enters the pipe (the rest is captured by the adapt)."
        ),
        WiringPipeline(
            key: "Circuit.Slideshow.updateConfig",
            title: "updateSlideshowConfig",
            input: "UUID",
            stages: [
                WiringStage(kind: .pipe, symbol: "Infrastructure.Slideshow.fetch", flows: "Slideshow?", note: "load current"),
                WiringStage(kind: .verb, symbol: nil, flows: "Slideshow", note: "require it exists", branches: ["✕ fail: NotFound"]),
                WiringStage(kind: .pipeAdapt, symbol: "Compute.Slideshow.applyConfig", flows: "Slideshow", note: "adapt → ApplyConfigComputePayload"),
                WiringStage(kind: .tap, symbol: "Infrastructure.Slideshow.save", flows: "Slideshow", note: "persist, keep flowing"),
                WiringStage(kind: .map, symbol: nil, flows: "SlideshowReturn", note: "SlideshowReturn.init"),
                WiringStage(kind: .effect, symbol: nil, flows: "SlideshowReturn", note: "publishSlideshow"),
            ],
            note: "Dispatch payload UpdateSlideshowConfigPayload; payload.slideshowID enters the pipe."
        ),
        WiringPipeline(
            key: "Circuit.Slideshow.open",
            title: "openSlideshow",
            input: "UUID",
            stages: [
                WiringStage(kind: .pipe, symbol: "Infrastructure.Slideshow.fetch", flows: "Slideshow?", note: "load detail"),
                WiringStage(kind: .verb, symbol: nil, flows: "Slideshow", note: "require it exists", branches: ["✕ fail: NotFound"]),
                WiringStage(kind: .map, symbol: nil, flows: "SlideshowReturn", note: "SlideshowReturn.init"),
                WiringStage(kind: .effect, symbol: nil, flows: "SlideshowReturn", note: "write SlideshowState"),
            ]
        ),
        WiringPipeline(
            key: "Circuit.Slideshow.close",
            title: "closeSlideshow",
            input: "CloseSlideshowPayload",
            stages: [
                WiringStage(kind: .effect, symbol: nil, flows: "—", note: "clear SlideshowState"),
            ],
            note: "No pipe: a direct buffer write (no kernel.run). Will be invisible to the L1-derived source — recorded here as a single effect for completeness."
        ),
        WiringPipeline(
            key: "Circuit.Slideshow.delete",
            title: "deleteSlideshow",
            input: "UUID",
            stages: [
                WiringStage(kind: .pipe, symbol: "Infrastructure.Slideshow.delete", flows: "Void", note: "delete from store"),
                WiringStage(kind: .effect, symbol: nil, flows: "Void", note: "remove catalog row + drop open detail"),
            ]
        ),
        WiringPipeline(
            key: "Circuit.Library.fetchAll",
            title: "fetchSlideshows",
            input: "Void",
            stages: [
                WiringStage(kind: .pipe, symbol: "Infrastructure.Library.fetchSummaries", flows: "[SlideshowSummary]", note: "load catalog summaries"),
                WiringStage(kind: .map, symbol: nil, flows: "[SlideshowSummaryReturn]", note: "project each summary"),
                WiringStage(kind: .effect, symbol: nil, flows: "[SlideshowSummaryReturn]", note: "commit LibraryState, isLoading=false"),
            ],
            note: "Pre-pipe: sets LibraryState.isLoading=true outside kernel.run (not a stage)."
        ),
        WiringPipeline(
            key: "Circuit.Config.save",
            title: "saveConfig",
            input: "SlideshowConfig",
            stages: [
                WiringStage(kind: .pipe, symbol: "Infrastructure.Config.save", flows: "Void", note: "persist config"),
            ],
            note: "Pre-pipe: builds SlideshowConfig from SaveConfigPayload outside kernel.run (not a stage)."
        ),
    ]
}

// MARK: - Layer palette

/// Colour a node by the layer its symbol lives in (the dotted prefix). Anonymous
/// stages (map/effect/verb) have no symbol, so they read neutral grey.
private func layerColor(_ symbol: String?) -> Color {
    switch symbol?.split(separator: ".").first {
    case "Presentation":   return .pink
    case "Circuit":        return .orange
    case "Compute":        return .green
    case "Infrastructure": return .blue
    default:               return .gray
    }
}

// MARK: - Root view (master-detail)

struct WiringGraphView: View {
    @State private var selectedKey: String? = WiringCatalog.pipelines.first?.key
    @State private var selectedStage: Int?
    @State private var search = ""
    @State private var mainLineOnly = false
    @State private var collapsed = false
    @State private var zoom: CGFloat = 1

    private var filtered: [WiringPipeline] {
        guard !search.isEmpty else { return WiringCatalog.pipelines }
        let q = search.lowercased()
        return WiringCatalog.pipelines.filter { p in
            p.title.lowercased().contains(q)
                || p.key.lowercased().contains(q)
                || p.stages.contains { ($0.symbol ?? "").lowercased().contains(q) }
        }
    }

    private var selectedPipeline: WiringPipeline? {
        WiringCatalog.pipelines.first { $0.key == selectedKey }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(width: 260)
            detailColumn
        }
        .frame(minWidth: 860, minHeight: 500)
        .onChange(of: selectedKey) { _, _ in selectedStage = nil }
    }

    // MARK: Left — fixed-width Circuit list

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $search).textFieldStyle(.plain)
            }
            .padding(8)
            Divider()
            List(selection: $selectedKey) {
                ForEach(filtered, id: \.key) { pipeline in
                    SidebarRow(pipeline: pipeline).tag(pipeline.key)
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: Right — toolbar + canvas + node detail

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if let pipeline = selectedPipeline {
                toolbar(pipeline)
                Divider()
                VSplitView {
                    canvas(pipeline).frame(minHeight: 240)
                    nodeDetail(pipeline).frame(minHeight: 120, idealHeight: 180)
                }
            } else {
                Text("Select a pipeline")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func toolbar(_ pipeline: WiringPipeline) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.title).font(.system(.headline, design: .monospaced))
                Text(pipeline.key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("main line only", isOn: $mainLineOnly)
                .toggleStyle(.switch).controlSize(.small)
                .help("Hide branch verbs and notes — show just the .next spine")
            Toggle("collapse", isOn: $collapsed)
                .toggleStyle(.switch).controlSize(.small)
                .help("Simplify anonymous map/effect stages to a compact row")
            Divider().frame(height: 16)
            Button { zoom = max(0.5, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
            Text("\(Int(zoom * 100))%").font(.caption).monospacedDigit().frame(width: 40)
            Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
            Button("Fit") { zoom = 1 }.controlSize(.small)
        }
        .padding(8)
    }

    // The downward node flow. Vertical primary; horizontal scroll only matters when
    // zoomed past the pane width.
    private func canvas(_ pipeline: WiringPipeline) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(spacing: 0) {
                EntryChip(type: pipeline.input)
                ForEach(Array(pipeline.stages.enumerated()), id: \.offset) { idx, stage in
                    FlowArrow(type: idx == 0 ? pipeline.input : pipeline.stages[idx - 1].flows)
                    StageNodeView(
                        stage: stage,
                        isSelected: selectedStage == idx,
                        mainLineOnly: mainLineOnly,
                        collapsed: collapsed
                    )
                    .onTapGesture { selectedStage = idx }
                }
            }
            .scaleEffect(zoom, anchor: .top)
            .padding(28)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Bottom — selected node inspector

    private func nodeDetail(_ pipeline: WiringPipeline) -> some View {
        ScrollView {
            if let idx = selectedStage, pipeline.stages.indices.contains(idx) {
                let stage = pipeline.stages[idx]
                let input = idx == 0 ? pipeline.input : pipeline.stages[idx - 1].flows
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(layerColor(stage.symbol)).frame(width: 11, height: 11)
                        Text(stage.symbol ?? "anonymous").font(.system(.headline, design: .monospaced))
                        Text(stage.kind.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(layerColor(stage.symbol).opacity(0.18)))
                    }
                    detailRow("payload", "\(input)  →  \(stage.flows)")
                    detailRow("emits", ([".next"] + stage.branches).joined(separator: "     "))
                    if let note = stage.note { detailRow("description", note) }
                    detailRow("implementation", stage.symbol == nil
                        ? "inline closure (no symbol)"
                        : "resolves once L1-derived — \(stage.symbol!)")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a node to inspect it")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let pipeline: WiringPipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pipeline.title).font(.system(.body, design: .monospaced))
            HStack(spacing: 8) {
                Text(pipeline.key.replacingOccurrences(of: "Circuit.", with: ""))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Label("\(pipeline.stages.count)", systemImage: "square.stack.3d.up.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                if pipeline.branchCount > 0 {
                    Label("\(pipeline.branchCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Canvas pieces

/// The pipe entry: the payload type that enters the chain.
private struct EntryChip: View {
    let type: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
            Text(type).font(.system(.callout, design: .monospaced))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().stroke(.secondary, lineWidth: 1))
    }
}

/// The `.next` wire: a downward arrow captioned with the type flowing across it.
private struct FlowArrow: View {
    let type: String
    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: "arrow.down").foregroundStyle(.secondary)
            Text(type).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

/// One stage as a node card: kind, the symbol it invokes (or "anonymous"), the
/// note, and any branch-verb badges. `mainLineOnly` strips notes + branches to the
/// spine; `collapsed` shrinks anonymous map/effect to a compact row.
private struct StageNodeView: View {
    let stage: WiringStage
    let isSelected: Bool
    let mainLineOnly: Bool
    let collapsed: Bool

    private var isAnonymous: Bool { stage.symbol == nil }
    private var isCompact: Bool {
        collapsed && isAnonymous && (stage.kind == .map || stage.kind == .effect)
    }

    var body: some View {
        Group {
            if isCompact { compactBody } else { fullBody }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : layerColor(stage.symbol),
                        lineWidth: isSelected ? 3 : 1.5)
        )
        .contentShape(Rectangle())
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stage.kind.rawValue)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(layerColor(stage.symbol))
            Text(stage.symbol ?? "anonymous")
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(isAnonymous ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            if !mainLineOnly, let note = stage.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !mainLineOnly {
                ForEach(stage.branches, id: \.self) { branch in
                    Text(branch).font(.caption.weight(.medium)).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private var compactBody: some View {
        HStack(spacing: 8) {
            Text(stage.kind.rawValue)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.gray)
            Text(stage.note ?? "anonymous").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(width: 360, alignment: .leading)
    }
}

// MARK: - Window

private final class WiringGraphPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Wiring Graph"
        // Behave like an ordinary window — no always-on-top. (Set `isFloatingPanel`
        // / `level = .floating` to pin it above other windows.)
        isFloatingPanel = false
        level = .normal
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}

/// Opens/closes the wiring graph as a single floating panel. App wires a Debug menu
/// command to `toggle`. Mirrors `KernelMonitorWindow`; takes no kernel because the
/// first-step source is static.
@MainActor
package enum WiringGraphWindow {
    private static var panel: NSPanel?

    package static func toggle() {
        if let panel {
            panel.close()
            Self.panel = nil
            return
        }
        let panel = WiringGraphPanel()
        panel.contentView = NSHostingView(rootView: WiringGraphView())
        panel.center()
        panel.orderFront(nil)
        Self.panel = panel
    }
}
#endif
