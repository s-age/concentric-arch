#if DEBUG
import Foundation
// Scoped: `Kernel` also names a class in this module, so a blanket `import
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
///   1. `@callable("<device>")` names the port protocol (in `Contract/Ports`).
///   2. Some concrete type's inheritance clause names that protocol, somewhere
///      under the device's own layer directory (`Sources/<Layer>`).
/// The conformance-declaring file isn't always the file with the method bodies
/// (Infrastructure declares `extension Store: Port {}` as a bare marker,
/// separate from where the store's methods are actually implemented), so
/// resolution is two hops: protocol name → conforming type name → wherever
/// that type name's own declaration/extension actually defines the method.
/// Every file is re-read and re-parsed on each call — same "reflects whatever
/// is on disk right now" behaviour the old regex search had, just parsed
/// instead of guessed.

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

/// Finds the protocol `@callable("<device>")` is attached to.
private final class CallableProtocolVisitor: SyntaxVisitor {
    private let device: String
    var found: String?

    init(device: String) {
        self.device = device
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.attributes {
            guard case .attribute(let attribute) = element,
                  attribute.attributeName.trimmedDescription == "callable",
                  let args = attribute.arguments?.as(LabeledExprListSyntax.self),
                  let literal = args.first?.expression.as(StringLiteralExprSyntax.self),
                  literal.representedLiteralValue == device
            else { continue }
            found = node.name.text
        }
        return found == nil ? .visitChildren : .skipChildren
    }
}

private func protocolName(forDevice device: String, portsDirectory: String) -> String? {
    for file in swiftFiles(under: portsDirectory) {
        guard let tree = parsed(file) else { continue }
        let visitor = CallableProtocolVisitor(device: device)
        visitor.walk(tree)
        if let found = visitor.found { return found }
    }
    return nil
}

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

/// Finds `func <method>`'s declaration inside any declaration/extension of
/// `typeName` in a single parsed file (name match only — this codebase has no
/// same-named overloads across a device's methods; a structural match already
/// rules out the old regex's comment/string false hits).
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

/// Resolves a symbol id (`Layer.Device.method`) to its concrete implementation's
/// `func` declaration, purely structurally — see the file-level doc for the
/// two-hop rationale. `nil` on any miss (caller falls back to the wire-site).
func resolveImplLocation(forSymbol id: String, repoRoot: String) -> SourceLocation? {
    let parts = id.split(separator: ".").map(String.init)
    guard parts.count >= 3 else { return nil }
    let layer = parts[0]
    let device = parts[0...1].joined(separator: ".")
    let method = parts[2...].joined(separator: ".")
    let portsDirectory = "\(repoRoot)/Sources/Contract/Ports"
    let layerDirectory = "\(repoRoot)/Sources/\(layer)"
    guard let protoName = protocolName(forDevice: device, portsDirectory: portsDirectory),
          let typeName = concreteTypeName(conformingTo: protoName, in: layerDirectory)
    else { return nil }
    return methodLocation(ofType: typeName, method: method, in: layerDirectory)
}
#endif
