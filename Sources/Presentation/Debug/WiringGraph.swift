#if DEBUG
import AppKit
import SwiftUI
import Kernel

/// A node-analysis view of the Circuit pipelines — opened from the Debug menu,
/// separate from the `KernelMonitor`. Where the monitor shows the *runtime* trace,
/// this shows the *shape*: each Circuit file expanded into its pipe stages.
///
/// Layout is master-detail: a fixed-width Circuit list on the left, the selected
/// pipeline's node flow (top-to-bottom) on the right, and a node-inspector below
/// the canvas. The downward flow keeps reading low-effort — no horizontal scrub.
///
/// The structure is now **derived by static introspection**, not hand-authored:
/// App reads each real `Pipe`'s `StageDescriptor`s (`circuitWiringIntrospection()`)
/// and injects them as `[WiringPipeline]`. Kind/symbol/flowing-type are all read
/// from the actual pipelines, so the picture cannot drift from the code.
///
/// What is *not* derivable stays out: the non-`.next` branch verbs (`.fail` guards)
/// live inside opaque closures, and prose descriptions are a separate concern — a
/// small per-symbol overlay (`symbolDescriptions`) supplies the "what it does" for
/// named nodes; anonymous map/effect stages name only their kind. Out-of-pipe work
/// (bare buffer writes, payload builds) arrives as a pipeline `note`.

// MARK: - Model

/// The builder method that minted a stage — its role in the pipe. Mirrors
/// `Kernel.StageDescriptor.Kind` (and the `PipeBuilder` surface in `Pipe.swift`).
enum StageKind: String {
    case pipe          // .pipe(symbol)               — invoke, its verb drives the pipe
    case pipeAdapt     // .pipe(symbol) { adapt }      — build the next payload, then invoke
    case verb          // .pipe { -> Verb }            — anonymous self-describing stage (a guard)
    case tap           // .tap(symbol)                 — side-effect, the value flows through
    case map           // .map(transform)              — pure projection
    case effect        // .effect { ... }              — effectful passthrough (a buffer write)
    case fork          // .fork(...)                   — parallel fan-out, order-preserving join
}

/// One node: a single pipe stage. `symbol` is the dotted id it invokes
/// (`Layer.Device.method`) or `nil` for an anonymous stage. `flows` is the type
/// leaving this stage — the label on the outgoing `.next` wire. `branches` lists
/// non-`.next` verbs (not statically derivable, so empty from the introspected
/// source — kept for a future annotation overlay).
package struct WiringStage {
    let kind: StageKind
    let symbol: String?
    let flows: String
    let note: String?
    var branches: [String] = []
    /// `.fork` only: each branch's own stage list (it is a sub-pipe), in fork's
    /// declared order. Empty for every other kind. Distinct from `branches` above
    /// (non-`.next` verb badges) — fork's fan-out is normal-path structure, not a
    /// warning annotation.
    var forkBranches: [[WiringStage]] = []
    /// Where this stage is wired in source (precise, from the builder). For an
    /// anonymous stage this is where its closure — the implementation — lives.
    let wireSite: SourceLocation?

    /// Map a Kernel `StageDescriptor` (the static shape) into a view node. The
    /// prose `note` is the symbol's own `description` — lifted by the `@callable`
    /// macro from the port method's doc comment — so there's no separate lookup to
    /// maintain. Anonymous stages (map/effect) carry none and show only their kind.
    package init(descriptor: StageDescriptor) {
        self.kind = StageKind(rawValue: descriptor.kind.rawValue) ?? .effect
        self.symbol = descriptor.symbolID
        self.flows = prettyType(descriptor.flows)
        self.note = descriptor.description
        self.branches = []
        self.forkBranches = descriptor.branches.map { $0.map(WiringStage.init(descriptor:)) }
        self.wireSite = descriptor.wireSite
    }
}

/// One Circuit file expanded: the dispatch key it backs, the payload that enters
/// the pipe, and the ordered stages. `note` carries out-of-pipe context (work that
/// happens around `kernel.run` and so is invisible to the static source).
package struct WiringPipeline {
    let key: String        // the dispatch key the pipe backs, e.g. "Circuit.Slideshow.update"
    let title: String      // the saga function, e.g. "updateSlideshow"
    let input: String      // the type fed into the pipe
    let stages: [WiringStage]
    var note: String? = nil

    var branchCount: Int { stages.reduce(0) { $0 + $1.branches.count } }

    package init(key: String, title: String, input: String, stages: [WiringStage], note: String?) {
        self.key = key
        self.title = title
        self.input = prettyType(input)
        self.stages = stages
        self.note = note
    }
}

/// `\(T.self)` renders `Optional<X>`/`Array<X>`; show the sugar form instead.
private func prettyType(_ raw: String) -> String {
    var s = raw.replacingOccurrences(of: "Swift.", with: "")
    if s.hasPrefix("Optional<"), s.hasSuffix(">") {
        s = String(s.dropFirst("Optional<".count).dropLast()) + "?"
    } else if s.hasPrefix("Array<"), s.hasSuffix(">") {
        s = "[" + String(s.dropFirst("Array<".count).dropLast()) + "]"
    }
    return s == "()" ? "Void" : s
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

// MARK: - Source navigation
//
// Opening the code behind a node is this architecture's missing piece: symbol-keyed
// dispatch means Xcode's jump-to-definition dead-ends at the port protocol, never the
// concrete handler. Two targets per node:
//   • wire-site  — precise (file:line, captured by the builder). For an anonymous
//                  stage this IS its implementation (the closure). Non-rotting.
//   • impl       — the concrete leaf handler, resolved by CONVENTION from the symbol
//                  id (best-effort — may drift if files move). This same table is the
//                  seed of generating Drivers from convention instead of hand-writing.

/// Symbol id (`Layer.Device.method`) → the concrete implementation file, relative to
/// the repo root. Best-effort convention; a miss just falls back to the wire-site.
private func implRelativePath(forSymbol id: String) -> String? {
    let device = id.split(separator: ".").prefix(2).joined(separator: ".")
    switch device {
    case "Compute.Slideshow":       return "Sources/Compute/SlideshowCompute.swift"
    case "Compute.Image":           return "Sources/Compute/ImageCompute.swift"
    case "Infrastructure.Slideshow",
         "Infrastructure.Library":  return "Sources/Infrastructure/Slideshow/Slideshow.swift"
    case "Infrastructure.Config":   return "Sources/Infrastructure/Config/ConfigStore.swift"
    default:                        return nil
    }
}

/// Derive the repo root from any absolute source path under `<root>/Sources/…`
/// (every wire-site is such a path), so convention-relative impl paths can anchor.
private func repoRoot(from absolutePath: String) -> String? {
    guard let r = absolutePath.range(of: "/Sources/") else { return nil }
    return String(absolutePath[absolutePath.startIndex..<r.lowerBound])
}

/// The concrete-impl location for a symbol node (convention), anchored to the repo
/// root taken from the node's own wire-site. `nil` for anonymous nodes or a miss.
/// Line is the method's `func` declaration when found by convention, else 1.
private func implLocation(for stage: WiringStage) -> SourceLocation? {
    guard let symbol = stage.symbol,
          let rel = implRelativePath(forSymbol: symbol),
          let site = stage.wireSite,
          let root = repoRoot(from: site.file)
    else { return nil }
    let file = "\(root)/\(rel)"
    let method = symbol.split(separator: ".").dropFirst(2).joined(separator: ".")
    return SourceLocation(file: file, line: methodDeclarationLine(in: file, method: method) ?? 1)
}

/// The line of `func <method>`'s declaration in `file`, by convention (best-effort
/// text search, not an AST parse). Comment lines are skipped so a docstring or a
/// commented-out declaration mentioning the name can't produce a false hit.
private func methodDeclarationLine(in file: String, method: String) -> Int? {
    guard !method.isEmpty,
          let text = try? String(contentsOfFile: file, encoding: .utf8),
          let regex = try? NSRegularExpression(
              pattern: #"^(?:(?:package|public|internal|fileprivate|private|open)\s+)*"#
                  + #"(?:static\s+|final\s+|mutating\s+|nonisolated\s+)*func\s+"#
                  + NSRegularExpression.escapedPattern(for: method) + #"\s*[(<]"#
          )
    else { return nil }
    for (index, line) in text.components(separatedBy: .newlines).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { continue }
        if regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return index + 1
        }
    }
    return nil
}

private func fileName(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}

/// Open a source location in the system editor for `.swift`. If that editor is
/// Xcode, jump to the line via `xed`; otherwise open the file (line-level jump is
/// editor-specific). This is the icon's action — the way out of the GUI into code.
@MainActor
private func openInEditor(_ loc: SourceLocation) {
    let url = URL(fileURLWithPath: loc.file)
    if loc.line > 1,
       let app = NSWorkspace.shared.urlForApplication(toOpen: url),
       Bundle(url: app)?.bundleIdentifier == "com.apple.dt.Xcode" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
        process.arguments = ["--line", "\(loc.line)", loc.file]
        do { try process.run() } catch { NSWorkspace.shared.open(url) }
    } else {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Root view (master-detail)

struct WiringGraphView: View {
    @State private var selectedKey: String?
    @State private var selectedStage: Int?
    @State private var search = ""
    @State private var mainLineOnly = false
    @State private var collapsed = false
    @State private var zoom: CGFloat = 1

    /// The introspected pipelines, injected by App (composition root) from the real
    /// Circuit pipes — this view does not depend on Circuit.
    private let pipelines: [WiringPipeline]

    package init(pipelines: [WiringPipeline]) {
        self.pipelines = pipelines
        _selectedKey = State(initialValue: pipelines.first?.key)
    }

    private var filtered: [WiringPipeline] {
        guard !search.isEmpty else { return pipelines }
        let q = search.lowercased()
        return pipelines.filter { p in
            p.title.lowercased().contains(q)
                || p.key.lowercased().contains(q)
                || p.stages.contains { ($0.symbol ?? "").lowercased().contains(q) }
        }
    }

    private var selectedPipeline: WiringPipeline? {
        pipelines.first { $0.key == selectedKey }
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
            if let site = pipeline.stages.first?.wireSite {
                Button { openInEditor(site) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help("Open the saga (\(fileName(site.file))) in the editor")
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
                    if stage.kind == .fork, !mainLineOnly, !stage.forkBranches.isEmpty {
                        ForkBranchesView(
                            branches: stage.forkBranches,
                            entryType: idx == 0 ? pipeline.input : pipeline.stages[idx - 1].flows,
                            mainLineOnly: mainLineOnly,
                            collapsed: collapsed
                        )
                    }
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
                        Text(stage.symbol ?? stage.note ?? "anonymous").font(.system(.headline, design: .monospaced))
                        Text(stage.kind.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(layerColor(stage.symbol).opacity(0.18)))
                    }
                    detailRow("payload", "\(input)  →  \(stage.flows)")
                    detailRow("emits", ([".next"] + stage.branches).joined(separator: "     "))
                    if stage.kind == .fork { detailRow("branches", "\(stage.forkBranches.count)") }
                    if let note = stage.note { detailRow("description", note) }
                    if let impl = implLocation(for: stage) {
                        openRow("implementation", "\(fileName(impl.file))  (convention)", impl)
                    }
                    if let site = stage.wireSite {
                        openRow(stage.symbol == nil ? "closure" : "wire-site",
                                "\(fileName(site.file)):\(site.line)", site)
                    }
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

    /// A detail row whose value is a clickable link that opens the location in the
    /// system's `.swift` editor.
    private func openRow(_ label: String, _ value: String, _ loc: SourceLocation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Button { openInEditor(loc) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.square")
                    Text(value).font(.system(.callout, design: .monospaced))
                }
            }
            .buttonStyle(.link)
            Spacer()
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

/// The nested fan-out under a `.fork` node: one vertical mini-flow per branch,
/// side by side, each fed the same `entryType` (the value fork copies to every
/// branch). Read-only — no selection/inspector wiring, unlike the main spine —
/// but each branch's own `StageNodeView` still opens its wire-site/impl directly.
/// The main spine's own `FlowArrow` below this (captioned with the fork's own
/// `flows`, the joined tuple/array) is what visually reads as the rejoin.
private struct ForkBranchesView: View {
    let branches: [[WiringStage]]
    let entryType: String
    let mainLineOnly: Bool
    let collapsed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(Array(branches.enumerated()), id: \.offset) { _, stages in
                VStack(spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { idx, stage in
                        FlowArrow(type: idx == 0 ? entryType : stages[idx - 1].flows)
                        StageNodeView(stage: stage, isSelected: false, mainLineOnly: mainLineOnly, collapsed: collapsed)
                    }
                }
            }
        }
        .padding(.top, 4)
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

    /// The node's primary "open" target: the concrete impl for a symbol node, else
    /// the wire-site (which, for an anonymous stage, is its closure).
    private var primaryTarget: SourceLocation? { implLocation(for: stage) ?? stage.wireSite }

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
            HStack(alignment: .firstTextBaseline) {
                Text(stage.kind.rawValue)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(layerColor(stage.symbol))
                Spacer()
                if let target = primaryTarget {
                    Button { openInEditor(target) } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help(stage.symbol == nil
                          ? "Open this stage's closure in the editor"
                          : "Open the implementation in the editor (convention)")
                }
            }
            if let symbol = stage.symbol {
                Text(symbol)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.primary)
                if !mainLineOnly, let note = stage.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let note = stage.note, !mainLineOnly {
                // Anonymous: its label is the node's identity — show it as the headline.
                Text(note).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Unlabelled (or main-line-only): fall back to the kind, never a bare "anonymous".
                Text(stage.kind.rawValue)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
            Text(stage.note ?? stage.kind.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
/// command to `toggle`, passing the pipelines it introspected from the real Circuit
/// pipes (App is the composition root that can see Circuit; this view cannot).
@MainActor
package enum WiringGraphWindow {
    private static var panel: NSPanel?

    package static func toggle(pipelines: [WiringPipeline]) {
        if let panel {
            panel.close()
            Self.panel = nil
            return
        }
        let panel = WiringGraphPanel()
        panel.contentView = NSHostingView(rootView: WiringGraphView(pipelines: pipelines))
        panel.center()
        panel.orderFront(nil)
        Self.panel = panel
    }
}
#endif
