import SwiftSyntax
import SwiftSyntaxMacros
import SwiftCompilerPlugin
import SwiftDiagnostics
import Foundation

private struct CallableMacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Warning surfaced when a `@callable` requirement carries no doc comment — its
/// generated `Symbol` gets no `description`, so the part shows blank in the wiring
/// graph. The "hole" is made visible at build time (cf. the wiring-totality stance).
private struct UndocumentedCallable: DiagnosticMessage {
    let name: String
    var message: String {
        "@callable method '\(name)' has no doc comment — its symbol will carry no description (blank in the wiring graph)"
    }
    var diagnosticID: MessageID { MessageID(domain: "CallableMacro", id: "undocumented") }
    var severity: DiagnosticSeverity { .warning }
}

/// The `///` (or `/** */`) doc comment attached to a declaration, collapsed to a
/// single line — lifted into the generated `Symbol.description` so "what this part
/// does" is data on the symbol, sourced from the one place it's declared.
private func docComment(of decl: some SyntaxProtocol) -> String? {
    var lines: [String] = []
    for piece in decl.leadingTrivia {
        switch piece {
        case .docLineComment(let text):                       // "/// …"
            let body = text.hasPrefix("///") ? String(text.dropFirst(3)) : text
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        case .docBlockComment(let text):                      // "/** … */"
            var body = text
            if body.hasPrefix("/**") { body = String(body.dropFirst(3)) }
            if body.hasSuffix("*/") { body = String(body.dropLast(2)) }
            for raw in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("*") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
                if !line.isEmpty { lines.append(line) }
            }
        default:
            break
        }
    }
    let joined = lines.joined(separator: " ")
    return joined.isEmpty ? nil : joined
}

/// Escape a string for embedding inside a Swift `"…"` literal in generated source.
private func swiftStringLiteral(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// `@callable("Id.Prefix")` attached to a device protocol generates a peer
/// `<Protocol>Callable` enum that holds a typed `Symbol` per method requirement
/// (id = "Id.Prefix.<method>") plus a `wire(_:into:)` that registers each method's
/// implementation into a `KernelBuilder`.
///
/// The protocol's requirements are the single source of truth: conformance forces
/// the implementations (forward exactness), `any Protocol` use forces the surface
/// (reverse exactness), and this macro generates the dispatch keys + wiring — one
/// `register` per requirement, so none can be forgotten (compile-time totality).
/// Each method's `///` doc comment is lifted into its `Symbol.description`, so a
/// part's documentation is data on the symbol, written where the method is declared.
public struct CallableMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            throw CallableMacroError("@callable can only be attached to a protocol")
        }
        guard
            let args = node.arguments?.as(LabeledExprListSyntax.self),
            let literal = args.first?.expression.as(StringLiteralExprSyntax.self),
            let prefix = literal.representedLiteralValue
        else {
            throw CallableMacroError(#"@callable requires a string-literal id prefix, e.g. @callable("Compute.Slideshow")"#)
        }

        let protoName = proto.name.text
        var symbolLines: [String] = []
        var wireLines: [String] = []

        for member in proto.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self) else { continue }
            let name = fn.name.text
            let allParams = Array(fn.signature.parameterClause.parameters)

            // A leading `Kernel` parameter marks a *composing* handler — one that
            // routes back into the mesh. It binds via the composing `register`
            // overload `(Kernel, P) -> O`; the kernel is handed in at call time
            // (it doesn't exist at wire time). Everything after it is the payload.
            let isComposing = allParams.first?.type.trimmedDescription == "Kernel"
            let payloadParams = isComposing ? Array(allParams.dropFirst()) : allParams
            guard payloadParams.count <= 1 else {
                throw CallableMacroError("@callable: '\(name)' must take at most one payload parameter\(isComposing ? " (besides the leading Kernel)" : "")")
            }

            let payloadType = payloadParams.first?.type.trimmedDescription ?? "Void"
            let output = fn.signature.returnClause?.type.trimmedDescription ?? "Void"
            let effects = fn.signature.effectSpecifiers
            let effectPrefix = (effects?.throwsClause != nil ? "try " : "") + (effects?.asyncSpecifier != nil ? "await " : "")

            // Closure params: `kernel` (composing only) then `payload` or `_`.
            var closureParams: [String] = []
            if isComposing { closureParams.append("kernel") }
            closureParams.append(payloadParams.isEmpty ? "_" : "payload")

            // Call arguments to `device.<name>(…)`, honouring the payload label.
            var callArgs: [String] = []
            if isComposing { callArgs.append("kernel") }
            if let p = payloadParams.first {
                let label = p.firstName.text
                callArgs.append(label == "_" ? "payload" : "\(label): payload")
            }

            // The part's description: the method's doc comment, lifted as data.
            // A missing one is a visible hole — warned, not failed.
            let descriptionArg: String
            if let doc = docComment(of: fn) {
                descriptionArg = ", description: \(swiftStringLiteral(doc))"
            } else {
                descriptionArg = ""
                context.diagnose(Diagnostic(node: fn.name, message: UndocumentedCallable(name: name)))
            }

            symbolLines.append(#"    package static let \#(name) = Symbol<\#(payloadType), \#(output)>("\#(prefix).\#(name)"\#(descriptionArg))"#)
            wireLines.append("        builder.register(\(name)) { \(closureParams.joined(separator: ", ")) in \(effectPrefix)device.\(name)(\(callArgs.joined(separator: ", "))) }")
        }

        let enumName = "\(protoName)Callable"
        let generated: DeclSyntax = """
        package enum \(raw: enumName) {
        \(raw: symbolLines.joined(separator: "\n"))

            package static func wire(_ device: any \(raw: protoName), into builder: KernelBuilder) {
        \(raw: wireLines.joined(separator: "\n"))
            }
        }
        """
        return [generated]
    }
}

@main
struct CallableMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [CallableMacro.self]
}
