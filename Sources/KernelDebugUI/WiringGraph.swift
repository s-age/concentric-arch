#if DEBUG
import AppKit
import SwiftUI
import Kernel

/// A node-analysis view of the orchestration pipelines — opened from the Debug
/// menu, separate from the `KernelMonitor`. Where the monitor shows the *runtime*
/// trace, this shows the *shape*: each pipeline expanded into its pipe stages.
///
/// Layout is master-detail: a fixed-width pipeline list on the left, the selected
/// pipeline's node flow (top-to-bottom) on the right, and a node-inspector below
/// the canvas. The downward flow keeps reading low-effort — no horizontal scrub.
///
/// The structure is **derived by static introspection**, not hand-authored: the
/// composition root reads each real `Pipe`'s shape and injects it as
/// `[PipeDescriptor]` — the kernel's own carriers, consumed directly, no
/// re-encoding in between. Kind/symbol/flowing-type are all read from the actual
/// pipelines, so the picture cannot drift from the code. What is a *repository's*
/// convention — layer colours, key elision, the impl-jump resolver — arrives the
/// same way, via `WiringGraphConfiguration`.
///
/// What is *not* derivable stays out: the non-`.next` branch verbs (`.fail` guards)
/// live inside opaque closures. The prose on a named node is the symbol's own
/// `description` (lifted by the symbol generator from the port method's doc
/// comment, carried on `StageDescriptor`); anonymous map/effect stages name only
/// their kind. Out-of-pipe work (bare buffer writes, payload builds) arrives as a
/// pipeline `note`.

// MARK: - Model (Kernel's descriptors, rendered directly)

/// `\(T.self)` renders `Optional<X>`/`Array<X>`; show the sugar form instead.
/// Display-only sugar — applied at render, never baked into the descriptors.
private func prettyType(_ raw: String) -> String {
    var s = raw.replacingOccurrences(of: "Swift.", with: "")
    if s.hasPrefix("Optional<"), s.hasSuffix(">") {
        s = String(s.dropFirst("Optional<".count).dropLast()) + "?"
    } else if s.hasPrefix("Array<"), s.hasSuffix(">") {
        s = "[" + String(s.dropFirst("Array<".count).dropLast()) + "]"
    }
    return s == "()" ? "Void" : s
}

private extension StageDescriptor {
    /// The type leaving this stage — the label on its `.next` wire, sugared.
    var prettyFlows: String { prettyType(flows) }
}

private extension PipeDescriptor {
    /// The type entering the pipe, sugared.
    var prettyInput: String { prettyType(inputType) }
}

// MARK: - Source navigation
//
// Opening the code behind a node is this architecture's missing piece: symbol-keyed
// dispatch means Xcode's jump-to-definition dead-ends at the port protocol, never the
// concrete handler. Two targets per node:
//   • wire-site  — precise (file:line, captured by the builder). For an anonymous
//                  stage this IS its implementation (the closure). Non-rotting.
//   • impl       — the concrete leaf handler, resolved from the symbol id by the
//                  *injected* `WiringGraphConfiguration.resolveImplLocation`. The
//                  swift-syntax-backed resolver lives in the separate
//                  `KernelDebugUISyntaxTools` target (`makeImplLocationResolver`);
//                  keeping it out of this module is what lets a consumer skip the
//                  swift-syntax dependency entirely — without a resolver the node
//                  simply falls back to its wire-site.

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
    @Environment(\.wiringGraphConfiguration) private var configuration
    @State private var selectedKey: String?
    @State private var selectedStage: Int?
    @State private var search = ""
    @State private var mainLineOnly = false
    @State private var collapsed = false
    @State private var zoom: CGFloat = 1
    /// Keys visited before the current one, most-recent-last — a plain back
    /// stack (no forward/redo) for `divertsTo` jump links.
    @State private var navigationHistory: [String] = []

    /// The introspected pipelines, injected by the composition root from its real
    /// orchestration pipes — this view depends on Kernel's carriers only.
    private let pipelines: [PipeDescriptor]

    init(pipelines: [PipeDescriptor]) {
        self.pipelines = pipelines
        _selectedKey = State(initialValue: pipelines.first?.key)
    }

    private var filtered: [PipeDescriptor] {
        guard !search.isEmpty else { return pipelines }
        let q = search.lowercased()
        return pipelines.filter { p in
            p.title.lowercased().contains(q)
                || p.key.lowercased().contains(q)
                || p.stages.contains { ($0.symbolID ?? "").lowercased().contains(q) }
        }
    }

    private var selectedPipeline: PipeDescriptor? {
        pipelines.first { $0.key == selectedKey }
    }

    /// Dispatch key → title, so a `divertsTo` chip can show a human name instead
    /// of the raw key — and so a stage can tell whether its named target actually
    /// resolves to a descriptor in this catalog at all.
    private var titlesByKey: [String: String] {
        Dictionary(uniqueKeysWithValues: pipelines.map { ($0.key, $0.title) })
    }

    /// Follow a `divertsTo` jump link: stash the current key so "back" can
    /// return to it, then switch the canvas to the target.
    private func navigate(to key: String) {
        if let current = selectedKey, current != key {
            navigationHistory.append(current)
        }
        selectedKey = key
    }

    private func navigateBack() {
        guard let previous = navigationHistory.popLast() else { return }
        selectedKey = previous
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

    private func toolbar(_ pipeline: PipeDescriptor) -> some View {
        HStack(spacing: 12) {
            if !navigationHistory.isEmpty {
                Button { navigateBack() } label: { Image(systemName: "chevron.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to \(titlesByKey[navigationHistory.last ?? ""] ?? navigationHistory.last ?? "")")
            }
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
    private func canvas(_ pipeline: PipeDescriptor) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(spacing: 0) {
                EntryChip(type: pipeline.prettyInput)
                ForEach(Array(pipeline.stages.enumerated()), id: \.offset) { idx, stage in
                    FlowArrow(type: idx == 0 ? pipeline.prettyInput : pipeline.stages[idx - 1].prettyFlows)
                    StageNodeView(
                        stage: stage,
                        isSelected: selectedStage == idx,
                        mainLineOnly: mainLineOnly,
                        collapsed: collapsed,
                        titlesByKey: titlesByKey,
                        onNavigate: navigate
                    )
                    // `simultaneousGesture`, not `.onTapGesture`: the latter is
                    // exclusive and would swallow taps meant for the node's own
                    // buttons (open-in-editor, divertsTo links) before they ever
                    // fire.
                    .simultaneousGesture(TapGesture().onEnded { selectedStage = idx })
                    if stage.kind == .fork, !mainLineOnly, !stage.branches.isEmpty {
                        ForkBranchesView(
                            branches: stage.branches,
                            entryType: idx == 0 ? pipeline.prettyInput : pipeline.stages[idx - 1].prettyFlows,
                            mainLineOnly: mainLineOnly,
                            collapsed: collapsed,
                            titlesByKey: titlesByKey,
                            onNavigate: navigate
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

    private func nodeDetail(_ pipeline: PipeDescriptor) -> some View {
        ScrollView {
            if let idx = selectedStage, pipeline.stages.indices.contains(idx) {
                let stage = pipeline.stages[idx]
                let input = idx == 0 ? pipeline.prettyInput : pipeline.stages[idx - 1].prettyFlows
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(configuration.style.color(forSymbol: stage.symbolID)).frame(width: 11, height: 11)
                        Text(stage.symbolID ?? stage.description ?? "anonymous").font(.system(.headline, design: .monospaced))
                        Text(stage.kind.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(configuration.style.color(forSymbol: stage.symbolID).opacity(0.18)))
                    }
                    detailRow("payload", "\(input)  →  \(stage.prettyFlows)")
                    detailRow("emits", ".next")
                    if stage.kind == .fork { detailRow("branches", "\(stage.branches.count)") }
                    if let note = stage.description { detailRow("description", note) }
                    if let impl = configuration.implLocation(for: stage) {
                        openRow("implementation", "\(fileName(impl.file))  (resolved)", impl)
                    }
                    if let site = stage.wireSite {
                        openRow(stage.symbolID == nil ? "closure" : "wire-site",
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
    @Environment(\.wiringGraphConfiguration) private var configuration
    let pipeline: PipeDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pipeline.title).font(.system(.body, design: .monospaced))
            HStack(spacing: 8) {
                Text(configuration.style.sidebarKeyLabel(pipeline.key))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Label("\(pipeline.stages.count)", systemImage: "square.stack.3d.up.fill")
                    .font(.caption2).foregroundStyle(.secondary)
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
    let branches: [[StageDescriptor]]
    let entryType: String
    let mainLineOnly: Bool
    let collapsed: Bool
    let titlesByKey: [String: String]
    let onNavigate: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(Array(branches.enumerated()), id: \.offset) { _, stages in
                VStack(spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { idx, stage in
                        FlowArrow(type: idx == 0 ? entryType : stages[idx - 1].prettyFlows)
                        StageNodeView(
                            stage: stage,
                            isSelected: false,
                            mainLineOnly: mainLineOnly,
                            collapsed: collapsed,
                            titlesByKey: titlesByKey,
                            onNavigate: onNavigate
                        )
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// One stage as a node card: kind, the symbol it invokes (or "anonymous"), and
/// the note. `mainLineOnly` strips notes + divert chips to the spine; `collapsed`
/// shrinks anonymous map/effect to a compact row.
private struct StageNodeView: View {
    @Environment(\.wiringGraphConfiguration) private var configuration
    let stage: StageDescriptor
    let isSelected: Bool
    let mainLineOnly: Bool
    let collapsed: Bool
    let titlesByKey: [String: String]
    let onNavigate: (String) -> Void

    private var isAnonymous: Bool { stage.symbolID == nil }
    private var isCompact: Bool {
        collapsed && isAnonymous && (stage.kind == .map || stage.kind == .effect)
    }

    /// The node's primary "open" target: the concrete impl for a symbol node, else
    /// the wire-site (which, for an anonymous stage, is its closure).
    private var primaryTarget: SourceLocation? { configuration.implLocation(for: stage) ?? stage.wireSite }

    var body: some View {
        Group {
            if isCompact { compactBody } else { fullBody }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : configuration.style.color(forSymbol: stage.symbolID),
                        lineWidth: isSelected ? 3 : 1.5)
        )
        .contentShape(Rectangle())
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(stage.kind.rawValue)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(configuration.style.color(forSymbol: stage.symbolID))
                Spacer()
                if let target = primaryTarget {
                    Button { openInEditor(target) } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help(stage.symbolID == nil
                          ? "Open this stage's closure in the editor"
                          : "Open the implementation in the editor (resolved)")
                }
            }
            if let symbol = stage.symbolID {
                Text(symbol)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.primary)
                if !mainLineOnly, let note = stage.description {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let note = stage.description, !mainLineOnly {
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
                ForEach(stage.divertsTo, id: \.self) { key in
                    DivertLinkChip(targetKey: key, title: titlesByKey[key], onNavigate: onNavigate)
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
            Text(stage.description ?? stage.kind.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(width: 360, alignment: .leading)
    }
}

/// A `divertsTo` hint rendered as a jump link when `title` resolves (the key
/// matches a `PipeDescriptor` in this catalog), or as a dim, non-interactive
/// label when it doesn't — an unresolved chip is a passive drift detector: the
/// author named a target that no longer exists under that key.
private struct DivertLinkChip: View {
    let targetKey: String
    let title: String?
    let onNavigate: (String) -> Void

    var body: some View {
        if let title {
            Button { onNavigate(targetKey) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(title).font(.caption.weight(.medium))
                }
            }
            .buttonStyle(.link)
            .help("divert → \(targetKey)")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(targetKey).font(.caption)
            }
            .foregroundStyle(.tertiary)
            .help("divert → \(targetKey) (not found in this catalog — possibly stale)")
        }
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

/// Opens/closes the wiring graph as a single floating panel. The composition root
/// wires a Debug menu command to `toggle`, passing the `PipeDescriptor`s it
/// introspected from its real orchestration pipes (only the root can see them;
/// this view cannot), plus the repo conventions bundle — impl-jump resolver and
/// style.
@MainActor
public enum WiringGraphWindow {
    private static var panel: NSPanel?

    public static func toggle(
        pipelines: [PipeDescriptor],
        configuration: WiringGraphConfiguration = WiringGraphConfiguration()
    ) {
        if let panel {
            panel.close()
            Self.panel = nil
            return
        }
        let panel = WiringGraphPanel()
        panel.contentView = NSHostingView(
            rootView: WiringGraphView(pipelines: pipelines)
                .environment(\.wiringGraphConfiguration, configuration)
        )
        panel.center()
        panel.orderFront(nil)
        Self.panel = panel
    }
}
#endif
