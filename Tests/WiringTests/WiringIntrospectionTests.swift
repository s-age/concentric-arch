#if DEBUG
import Foundation
import Testing
import Kernel
import Contract
import Circuit
import Driver

// MARK: - Wiring-only stubs

// `wireAllDrivers` needs store *instances* to bind, but these tests read only the
// bound key set — no handler is ever invoked, so the stubs are unreachable.
private struct UnreachableSlideshowStore: LibraryStoring, SlideshowStoring {
    func fetchSummaries() async throws -> [SlideshowSummary] { fatalError("wiring-only stub — never invoked") }
    func fetch(id: UUID) async throws -> Slideshow? { fatalError("wiring-only stub — never invoked") }
    func save(_ slideshow: Slideshow) async throws { fatalError("wiring-only stub — never invoked") }
    func delete(id: UUID) async throws { fatalError("wiring-only stub — never invoked") }
}

private struct UnreachableConfigStore: ConfigStoring {
    func load() async throws -> SlideshowConfig { fatalError("wiring-only stub — never invoked") }
    func save(_ config: SlideshowConfig) async throws { fatalError("wiring-only stub — never invoked") }
}

/// Every symbol id the real Driver manifest binds — the compile-derived truth
/// (`@callable` emits one `register` per port requirement, so this set cannot
/// under-count an existing device's endpoints).
private func boundSymbolIDs() -> Set<String> {
    let builder = KernelBuilder()
    wireAllDrivers(
        into: builder,
        slideshowStore: UnreachableSlideshowStore(),
        config: UnreachableConfigStore()
    )
    return builder.boundSymbolIDs
}

/// Flatten a pipe's stage tree — `fork` branches are sub-pipes whose stages
/// (including nested `divertsTo` hints) must be visited too.
private func allDescriptors(in stages: [StageDescriptor]) -> [StageDescriptor] {
    stages.flatMap { [$0] + $0.branches.flatMap { allDescriptors(in: $0) } }
}

// MARK: - WiringIntrospection exhaustiveness (card 38)

// `circuitWiringIntrospection()` is a hand-maintained list; forgetting an entry
// used to drop the pipeline from the wiring graph with no compile-time or runtime
// signal. These tests turn that silent omission — and the reverse drift, a stale
// entry surviving its endpoint — into CI failures by cross-checking the list
// against the `Circuit.*` keys the real Driver manifest binds.

@Test func everyCircuitEndpointHasAnIntrospectionEntry() {
    let bound = boundSymbolIDs().filter { $0.hasPrefix("Circuit.") }
    let registered = Set(circuitWiringIntrospection().map(\.key))
    let missing = bound.subtracting(registered).sorted()
    #expect(
        missing.isEmpty,
        "Circuit endpoints absent from circuitWiringIntrospection() — add a PipeDescriptor(…) (or a pipe-less one with empty stages, cf. closeSlideshow) in Circuit/WiringIntrospection.swift: \(missing)"
    )
}

@Test func everyIntrospectionEntryBacksARealCircuitEndpoint() {
    let bound = boundSymbolIDs().filter { $0.hasPrefix("Circuit.") }
    let registered = Set(circuitWiringIntrospection().map(\.key))
    let stale = registered.subtracting(bound).sorted()
    #expect(
        stale.isEmpty,
        "circuitWiringIntrospection() keys with no wired Circuit endpoint behind them — remove or fix the entry: \(stale)"
    )
}

@Test func introspectionKeysAreUnique() {
    let keys = circuitWiringIntrospection().map(\.key)
    let duplicates = Dictionary(grouping: keys, by: { $0 }).filter { $1.count > 1 }.keys.sorted()
    #expect(duplicates.isEmpty, "Duplicate circuitWiringIntrospection() keys: \(duplicates)")
}

@Test func divertHintsResolveToCatalogKeys() {
    // `divertsTo` is author-named, never derived — the wiring graph renders an
    // unresolved hint as a dim "possibly stale" chip. Fail it here instead.
    let catalog = Set(circuitWiringIntrospection().map(\.key))
    let unresolved = circuitWiringIntrospection().flatMap { entry in
        allDescriptors(in: entry.stages)
            .flatMap(\.divertsTo)
            .filter { !catalog.contains($0) }
            .map { "\(entry.key) divertsTo \($0)" }
    }
    #expect(
        unresolved.isEmpty,
        "divertsTo hints naming no pipeline in the catalog (stale key or missing entry): \(unresolved)"
    )
}
#endif
