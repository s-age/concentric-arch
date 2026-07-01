#if DEBUG
@testable import Presentation
import Contract
import Testing

/// Every `@callable` symbol should resolve to a file that genuinely declares
/// `func <method>` at the reported line — the totality check for the wiring
/// graph's impl-location resolver, mirroring this codebase's other
/// wiring-exhaustiveness tests. Asserts *content*, not a hardcoded line number,
/// so it doesn't go brittle the moment someone edits above the declaration.
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
}
#endif
