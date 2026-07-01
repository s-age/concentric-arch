#if DEBUG
import Foundation
// Scoped: `Kernel` also names a class in that module, so a blanket `import
// Kernel` makes `SourceLocation` resolve to that class (no such member)
// instead of the module. Importing just the struct sidesteps the clash.
import struct Kernel.SourceLocation
import SwiftParser
import SwiftSyntax

/// Structural (SwiftSyntax) resolution of a symbol's concrete implementation —
/// replaces a hand-maintained device→file table plus a regex line search.
///
/// Two facts are already load-bearing for the code to compile, so reading them
/// back is enough to find the implementation without a separate table:
///   1. `@callable("<device>")` names the port protocol (under the ports
///      directory).
///   2. Some concrete type's inheritance clause names that protocol, somewhere
///      under the device's own layer directory.
/// The conformance-declaring file isn't always the file with the method bodies
/// (a storage layer may declare `extension Store: Port {}` as a bare marker,
/// separate from where the store's methods are actually implemented), so
/// resolution is two hops: protocol name → conforming type name → wherever
/// that type name's own declaration/extension actually defines the method.
/// Every file is re-read and re-parsed on each call — same "reflects whatever
/// is on disk right now" behaviour the old regex search had, just parsed
/// instead of guessed.
///
/// Which facts count — the attribute name, where ports and layers live, how a
/// symbol id decomposes — is a *repository's* convention, not this resolver's:
/// they are injected via `ImplSourceConventions` (defaults match the concentric
/// layout this tool grew up in).

// MARK: - Conventions (injected, not baked in)

/// The repository layout / naming conventions the resolver walks. A consumer
/// whose repo differs from the concentric defaults overrides the relevant
/// fields instead of forking the resolver.
public struct ImplSourceConventions: Sendable {
    /// Attribute (without `@`) that marks a port protocol and carries the
    /// device name as its first string literal, e.g. `@callable("Layer.Device")`.
    public var callableAttribute: String
    /// Path component that separates a repository root from its source files —
    /// used to derive the root from any absolute wire-site path.
    public var sourcesMarker: String
    /// Directory holding the port protocols, relative to the repository root.
    public var portsSubpath: String
    /// Directory holding a layer's concrete devices, relative to the repository
    /// root, given the layer name (a symbol id's first dotted component).
    public var layerSubpath: @Sendable (_ layer: String) -> String
    /// Decompose a symbol id into the layer to scan, the device the port's
    /// attribute names, and the method to locate. `nil` marks an id this
    /// convention cannot address (the resolver then reports a miss).
    public var splitSymbolID: @Sendable (_ id: String) -> (layer: String, device: String, method: String)?

    public init(
        callableAttribute: String = "callable",
        sourcesMarker: String = "/Sources/",
        portsSubpath: String = "Sources/Contract/Ports",
        layerSubpath: @escaping @Sendable (_ layer: String) -> String = { "Sources/\($0)" },
        splitSymbolID: @escaping @Sendable (_ id: String) -> (layer: String, device: String, method: String)? = { id in
            // `Layer.Device.method` — the concentric symbol-id convention.
            let parts = id.split(separator: ".").map(String.init)
            guard parts.count >= 3 else { return nil }
            return (
                layer: parts[0],
                device: parts[0...1].joined(separator: "."),
                method: parts[2...].joined(separator: ".")
            )
        }
    ) {
        self.callableAttribute = callableAttribute
        self.sourcesMarker = sourcesMarker
        self.portsSubpath = portsSubpath
        self.layerSubpath = layerSubpath
        self.splitSymbolID = splitSymbolID
    }
}

// MARK: - File walking

/// Recursively list `.swift` files under `directory` (empty if it doesn't exist).
private func swiftFiles(under directory: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
    return enumerator.compactMap { entry in
        (entry as? String).flatMap { $0.hasSuffix(".swift") ? "\(directory)/\($0)" : nil }
    }
}

private func parsed(_ file: String) -> SourceFileSyntax? {
    (try? String(contentsOfFile: file, encoding: .utf8)).map(Parser.parse(source:))
}

// MARK: - Hop 1: device → port protocol

/// Finds the protocol `@<attribute>("<device>")` is attached to.
private final class CallableProtocolVisitor: SyntaxVisitor {
    private let attributeName: String
    private let device: String
    var found: String?

    init(attributeName: String, device: String) {
        self.attributeName = attributeName
        self.device = device
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.attributes {
            guard case .attribute(let attribute) = element,
                  attribute.attributeName.trimmedDescription == attributeName,
                  let args = attribute.arguments?.as(LabeledExprListSyntax.self),
                  let literal = args.first?.expression.as(StringLiteralExprSyntax.self),
                  literal.representedLiteralValue == device
            else { continue }
            found = node.name.text
        }
        return found == nil ? .visitChildren : .skipChildren
    }
}

private func protocolName(forDevice device: String, attributeName: String, portsDirectory: String) -> String? {
    for file in swiftFiles(under: portsDirectory) {
        guard let tree = parsed(file) else { continue }
        let visitor = CallableProtocolVisitor(attributeName: attributeName, device: device)
        visitor.walk(tree)
        if let found = visitor.found { return found }
    }
    return nil
}

// MARK: - Hop 2: protocol → conforming type

/// Finds a type's name whose inheritance clause names `protocolName` — a
/// struct/class/actor declaration, or a bare `extension X: Protocol {}` marker.
private final class ConformanceVisitor: SyntaxVisitor {
    private let protocolName: String
    var found: String?

    init(protocolName: String) {
        self.protocolName = protocolName
        super.init(viewMode: .sourceAccurate)
    }

    private func matches(_ clause: InheritanceClauseSyntax?) -> Bool {
        clause?.inheritedTypes.contains { $0.type.trimmedDescription == protocolName } ?? false
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.inheritanceClause) { found = node.name.text }
        return found == nil ? .visitChildren : .skipChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.inheritanceClause) { found = node.name.text }
        return found == nil ? .visitChildren : .skipChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.inheritanceClause) { found = node.name.text }
        return found == nil ? .visitChildren : .skipChildren
    }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if matches(node.inheritanceClause) { found = node.extendedType.trimmedDescription }
        return found == nil ? .visitChildren : .skipChildren
    }
}

private func concreteTypeName(conformingTo protocolName: String, in directory: String) -> String? {
    for file in swiftFiles(under: directory) {
        guard let tree = parsed(file) else { continue }
        let visitor = ConformanceVisitor(protocolName: protocolName)
        visitor.walk(tree)
        if let found = visitor.found { return found }
    }
    return nil
}

// MARK: - Hop 3: type → method declaration

/// Finds `func <method>`'s declaration inside any declaration/extension of
/// `typeName` in a single parsed file (name match only — assumes no same-named
/// overloads across a device's methods; a structural match already rules out
/// the old regex's comment/string false hits).
private final class MethodVisitor: SyntaxVisitor {
    private let typeName: String
    private let method: String
    var found: AbsolutePosition?

    init(typeName: String, method: String) {
        self.typeName = typeName
        self.method = method
        super.init(viewMode: .sourceAccurate)
    }

    private func scanMembers(_ members: MemberBlockItemListSyntax) {
        for member in members {
            guard found == nil,
                  let fn = member.decl.as(FunctionDeclSyntax.self),
                  fn.name.text == method
            else { continue }
            found = fn.funcKeyword.positionAfterSkippingLeadingTrivia
        }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == typeName { scanMembers(node.memberBlock.members) }
        return found == nil ? .visitChildren : .skipChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == typeName { scanMembers(node.memberBlock.members) }
        return found == nil ? .visitChildren : .skipChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == typeName { scanMembers(node.memberBlock.members) }
        return found == nil ? .visitChildren : .skipChildren
    }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.extendedType.trimmedDescription == typeName { scanMembers(node.memberBlock.members) }
        return found == nil ? .visitChildren : .skipChildren
    }
}

private func methodLocation(ofType typeName: String, method: String, in directory: String) -> SourceLocation? {
    guard !method.isEmpty else { return nil }
    for file in swiftFiles(under: directory) {
        guard let tree = parsed(file) else { continue }
        let visitor = MethodVisitor(typeName: typeName, method: method)
        visitor.walk(tree)
        guard let position = visitor.found else { continue }
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        return SourceLocation(file: file, line: converter.location(for: position).line)
    }
    return nil
}

// MARK: - Entry points

/// Resolves a symbol id to its concrete implementation's `func` declaration,
/// purely structurally — see the file-level doc for the two-hop rationale.
/// `nil` on any miss (callers fall back to the wire-site).
public func resolveImplLocation(
    forSymbol id: String,
    repoRoot: String,
    conventions: ImplSourceConventions = ImplSourceConventions()
) -> SourceLocation? {
    guard let parts = conventions.splitSymbolID(id) else { return nil }
    let portsDirectory = "\(repoRoot)/\(conventions.portsSubpath)"
    let layerDirectory = "\(repoRoot)/\(conventions.layerSubpath(parts.layer))"
    guard let protoName = protocolName(
        forDevice: parts.device,
        attributeName: conventions.callableAttribute,
        portsDirectory: portsDirectory
    ),
          let typeName = concreteTypeName(conformingTo: protoName, in: layerDirectory)
    else { return nil }
    return methodLocation(ofType: typeName, method: parts.method, in: layerDirectory)
}

/// The wiring graph's injectable resolver: derives the repository root from the
/// stage's own wire-site (every wire-site is an absolute path under
/// `<root><sourcesMarker>…`), then resolves the symbol against that root. Pass
/// the result to `WiringGraphConfiguration(resolveImplLocation:)` — this
/// closure is the entire coupling between the graph UI and swift-syntax.
public func makeImplLocationResolver(
    conventions: ImplSourceConventions = ImplSourceConventions()
) -> @Sendable (_ symbolID: String, _ wireSite: SourceLocation) -> SourceLocation? {
    { symbolID, wireSite in
        guard let range = wireSite.file.range(of: conventions.sourcesMarker) else { return nil }
        let repoRoot = String(wireSite.file[wireSite.file.startIndex..<range.lowerBound])
        return resolveImplLocation(forSymbol: symbolID, repoRoot: repoRoot, conventions: conventions)
    }
}
#endif
