#if DEBUG
import Foundation
import KernelDebugUISyntaxTools
import Testing

// The framework's own DebugToolingTests (../swift-kernelee) prove the resolver
// walks the conventions correctly — against a fixture tree. What only this
// repository can prove is the other half of the contract: that *our* layout
// still follows the default `ImplSourceConventions` the wiring graph runs
// with, so the impl-jump works for every leaf endpoint we actually bind. A
// renamed directory or a conformance shape the two-hop walk can't see would
// otherwise degrade the jump silently (the graph just falls back to the
// wire-site).

private let repoRoot: String = {
    let file = #filePath
    guard let r = file.range(of: "/Tests/") else { fatalError("expected test file under Tests/") }
    return String(file[file.startIndex..<r.lowerBound])
}()

/// Every leaf-device symbol the real Driver manifest binds must resolve to a
/// file that genuinely declares `func <method>` at the reported line. The
/// denominator is derived (`boundSymbolIDs()`), not hand-listed, so a new
/// endpoint is covered the moment it is wired. Circuit endpoints are excluded:
/// the graph jumps to their pipe factories via wire-site capture, not the
/// resolver.
@Test func everyBoundLeafSymbolResolvesToItsImplementation() throws {
    let leafIDs = boundSymbolIDs()
        .filter { $0.hasPrefix("Compute.") || $0.hasPrefix("Infrastructure.") }
        .sorted()
    #expect(!leafIDs.isEmpty, "no leaf symbols bound — wiring changed shape?")
    for id in leafIDs {
        let loc = try #require(
            resolveImplLocation(forSymbol: id, repoRoot: repoRoot),
            "\(id) no longer resolves — has the repo layout drifted from the default ImplSourceConventions?"
        )
        let lines = try String(contentsOfFile: loc.file, encoding: .utf8).components(separatedBy: .newlines)
        #expect(loc.line >= 1 && loc.line <= lines.count)
        let method = id.split(separator: ".").dropFirst(2).joined(separator: ".")
        #expect(
            lines[loc.line - 1].contains("func \(method)"),
            "\(id) resolved to \(loc.file):\(loc.line), which does not declare func \(method)"
        )
    }
}
#endif
