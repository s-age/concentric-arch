#if DEBUG
import SwiftUI
import struct Kernel.SourceLocation

/// Everything about the wiring graph that is *a repository's convention*, not
/// the graph's own logic — injected by the composition root so the view stays
/// convention-free. Defaults reproduce the concentric layout this tool grew up
/// in; a consumer with different layer names (or none) overrides them.

/// Resolves a symbol node's concrete implementation from its id and the stage's
/// wire-site. `nil` means "no impl jump for this node" (the graph falls back to
/// the wire-site). The swift-syntax-backed implementation lives in the separate
/// `KernelDebugUISyntaxTools` target (`makeImplLocationResolver`) precisely so
/// that a consumer who leaves this `nil` never links swift-syntax at all.
public typealias ImplLocationResolving = @Sendable (_ symbolID: String, _ wireSite: SourceLocation) -> SourceLocation?

/// Visual conventions: how a symbol's layer prefix maps to a node colour, and
/// which key prefix the sidebar elides as noise.
public struct WiringGraphStyle: Sendable {
    /// Node colour per layer name (a symbol id's first dotted component).
    public var layerColors: [String: Color]
    /// Colour for anonymous stages (map/effect/verb — no symbol) and for
    /// layers absent from `layerColors`.
    public var defaultColor: Color
    /// Prefix stripped from a pipeline key in the sidebar's secondary line
    /// (every key shares it, so it carries no information there). `nil` shows
    /// keys verbatim.
    public var elidedKeyPrefix: String?

    public init(
        layerColors: [String: Color] = [
            "Presentation": .pink,
            "Circuit": .orange,
            "Compute": .green,
            "Infrastructure": .blue,
        ],
        defaultColor: Color = .gray,
        elidedKeyPrefix: String? = "Circuit."
    ) {
        self.layerColors = layerColors
        self.defaultColor = defaultColor
        self.elidedKeyPrefix = elidedKeyPrefix
    }

    /// Colour a node by the layer its symbol lives in (the dotted prefix).
    func color(forSymbol symbol: String?) -> Color {
        guard let layer = symbol?.split(separator: ".").first else { return defaultColor }
        return layerColors[String(layer)] ?? defaultColor
    }

    /// The sidebar's secondary line for a pipeline key.
    func sidebarKeyLabel(_ key: String) -> String {
        guard let prefix = elidedKeyPrefix, key.hasPrefix(prefix) else { return key }
        return String(key.dropFirst(prefix.count))
    }
}

/// The injected bundle the graph reads through the SwiftUI environment.
public struct WiringGraphConfiguration: Sendable {
    public var style: WiringGraphStyle
    public var resolveImplLocation: ImplLocationResolving?

    public init(
        style: WiringGraphStyle = WiringGraphStyle(),
        resolveImplLocation: ImplLocationResolving? = nil
    ) {
        self.style = style
        self.resolveImplLocation = resolveImplLocation
    }

    /// The concrete-impl location for a symbol node, or `nil` for an anonymous
    /// node, a miss, or when no resolver was injected.
    func implLocation(for stage: WiringStage) -> SourceLocation? {
        guard let resolve = resolveImplLocation,
              let symbol = stage.symbol,
              let site = stage.wireSite
        else { return nil }
        return resolve(symbol, site)
    }
}

private struct WiringGraphConfigurationKey: EnvironmentKey {
    static let defaultValue = WiringGraphConfiguration()
}

extension EnvironmentValues {
    var wiringGraphConfiguration: WiringGraphConfiguration {
        get { self[WiringGraphConfigurationKey.self] }
        set { self[WiringGraphConfigurationKey.self] = newValue }
    }
}
#endif
