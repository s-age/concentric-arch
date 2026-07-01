#if DEBUG
import Contract
import struct Kernel.SourceLocation
import KernelDebugUISyntaxTools
import Testing

/// Every `@callable` symbol should resolve to a file that genuinely declares
/// `func <method>` at the reported line — the totality check for the wiring
/// graph's impl-location resolver, mirroring this codebase's other
/// wiring-exhaustiveness tests. Asserts *content*, not a hardcoded line number,
/// so it doesn't go brittle the moment someone edits above the declaration.
/// The default `ImplSourceConventions` under test *are* this repository's
/// conventions — that identity is the point of the check.
private let repoRoot: String = {
    let file = #filePath
    guard let r = file.range(of: "/Tests/") else { fatalError("expected test file under Tests/") }
    return String(file[file.startIndex..<r.lowerBound])
}()

@Suite struct ImplLocationResolverTests {
    @Test(arguments: [
        Callable.Compute.Slideshow.create.id,
        Callable.Compute.Slideshow.update.id,
        Callable.Compute.Slideshow.applyConfig.id,
        Callable.Compute.Image.addDroppedFiles.id,
        Callable.Infrastructure.Library.fetchSummaries.id,
        Callable.Infrastructure.Slideshow.fetch.id,
        Callable.Infrastructure.Slideshow.save.id,
        Callable.Infrastructure.Slideshow.delete.id,
        Callable.Infrastructure.Config.load.id,
        Callable.Infrastructure.Config.save.id,
    ])
    func resolvesToTheRealDeclaration(symbolID: String) throws {
        let loc = try #require(resolveImplLocation(forSymbol: symbolID, repoRoot: repoRoot))
        let lines = try String(contentsOfFile: loc.file, encoding: .utf8).components(separatedBy: .newlines)
        #expect(loc.line >= 1 && loc.line <= lines.count)
        let method = symbolID.split(separator: ".").dropFirst(2).joined(separator: ".")
        #expect(lines[loc.line - 1].contains("func \(method)"))
    }

    /// The injectable form (what the composition root hands the wiring graph)
    /// must derive the repo root from a stage's wire-site path on its own —
    /// the `/Sources/` anchoring that used to live inside the graph view.
    @Test func derivesTheRepoRootFromAWireSitePath() throws {
        let resolve = makeImplLocationResolver()
        let wireSite = SourceLocation(file: "\(repoRoot)/Sources/Circuit/AnySaga.swift", line: 1)
        let loc = try #require(resolve(Callable.Infrastructure.Slideshow.fetch.id, wireSite))
        #expect(loc.file.hasPrefix("\(repoRoot)/Sources/Infrastructure/"))
    }

    /// A convention override reroutes the walk: pointing the ports directory
    /// somewhere empty must turn every resolution into a clean miss (`nil`),
    /// proving the layout is read from the config, not baked in.
    @Test func conventionsAreInjectedNotBakedIn() {
        let elsewhere = ImplSourceConventions(portsSubpath: "Sources/Nowhere")
        let loc = resolveImplLocation(
            forSymbol: Callable.Infrastructure.Slideshow.fetch.id,
            repoRoot: repoRoot,
            conventions: elsewhere
        )
        #expect(loc == nil)
    }
}
#endif
