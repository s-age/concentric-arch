import Foundation
import Testing
@testable import Kernel

// MARK: - Fixtures

private let increment = Symbol<Int, Int>("test.increment")
private let stringify = Symbol<Int, String>("test.stringify")
private let length = Symbol<String, Int>("test.length")
private let erase = Symbol<Int, Void>("test.erase")
/// A verb-returning leaf: the *Driver* decides the verb (`.fail` on negative).
private let guarded = Symbol<Int, Int>("test.guarded")
/// A side-effecting leaf for `.tap`: `Void` output, `.fail` on negative.
private let guardedSink = Symbol<Int, Void>("test.guardedSink")

/// Records which stages actually executed, to prove the terminators discard the rest.
private actor Probe {
    private(set) var hits: [String] = []
    func hit(_ name: String) { hits.append(name) }
}

/// Build a kernel wired with the leaf fixtures. `@MainActor` only because the
/// `Buffer` builder is; the resulting `Kernel` is `Sendable` and used off-actor.
@MainActor
private func makeKernel() -> Kernel {
    let builder = KernelBuilder()
    builder.register(increment) { $0 + 1 }
    builder.register(stringify) { "\($0)" }
    builder.register(length) { $0.count }
    builder.register(erase) { _ in () }
    builder.register(guarded) { n -> Verb<Int> in n < 0 ? .fail(Boom()) : .next(n * 2) }
    builder.register(guardedSink) { n -> Verb<Void> in n < 0 ? .fail(Boom()) : .next(()) }
    return builder.build(buffer: BufferBuilder().build())
}

// MARK: - .next chain (the load-bearing static guarantee)

@Test
func nextChainsReturnIntoNextPayload() async throws {
    let kernel = await makeKernel()
    // 9 -> +1 -> 10 -> "10" -> length -> 2
    let pipe = pipeline(increment).pipe(stringify).pipe(length).seal()
    let result: Int = try await kernel.compose(pipe, 9)
    #expect(result == 2)
}

@Test
func builderCanBeComposedWithoutExplicitSeal() async throws {
    let kernel = await makeKernel()
    let result = try await kernel.compose(pipeline(increment).pipe(increment), 40)
    #expect(result == 42)
}

@Test
func voidOutputRoundTrips() async throws {
    let kernel = await makeKernel()
    let pipe = pipeline(increment).pipe(erase).seal() // Pipe<Int, Void>
    try await kernel.compose(pipe, 0) // must not throw on the Void boundary cast
}

// MARK: - Verb-returning handlers (the Driver owns the verb)

@Test
func verbReturningHandlerIsInterpretedByCall() async throws {
    let kernel = await makeKernel()
    // `call` interprets the handler's verb down to the symbol's Output.
    #expect(try await kernel.call(guarded, 3) == 6)
    await #expect(throws: Boom.self) {
        _ = try await kernel.call(guarded, -1)
    }
}

@Test
func verbReturningHandlerDrivesThePipe() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    // No wrapper closure: `guarded`'s own `.fail`/`.next` controls the pipe.
    let pipe = pipeline(guarded)
        .pipe { _, n in await probe.hit("downstream"); return .next(n) }
        .seal()

    #expect(try await kernel.compose(pipe, 5) == 10) // .next(10) -> downstream
    #expect(await probe.hits == ["downstream"])

    await #expect(throws: Boom.self) {
        _ = try await kernel.compose(pipe, -1) // handler .fail -> pipe throws
    }
    #expect(await probe.hits == ["downstream"]) // failing handler skipped downstream
}

// MARK: - tap / map / effect (declarative chain links)

@Test
func tapRunsTheSymbolButForwardsTheOriginalValue() async throws {
    let kernel = await makeKernel()
    // increment -> 6, tap(guardedSink) runs for effect, original 6 keeps flowing
    let pipe = pipeline(increment).tap(guardedSink).map { $0 + 100 }.seal()
    #expect(try await kernel.compose(pipe, 5) == 106)
}

@Test
func tapHonorsAFailFromTheTappedDriver() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    let pipe = pipeline(increment)
        .tap(guardedSink) // -9 < 0 -> .fail
        .effect { _, _ in await probe.hit("downstream") }
        .seal()
    await #expect(throws: Boom.self) {
        _ = try await kernel.compose(pipe, -10)
    }
    #expect(await probe.hits.isEmpty)
}

@Test
func mapTransformsAndEffectPassesThrough() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    let pipe = pipeline(increment)        // 0 -> 1
        .effect { _, n in await probe.hit("eff:\(n)") }
        .map { $0 + 1 }                   // 1 -> 2
        .seal()
    #expect(try await kernel.compose(pipe, 0) == 2)
    #expect(await probe.hits == ["eff:1"])
}

@Test
func pipeWithAdapterBuildsTheSymbolPayloadFromTheCursor() async throws {
    let kernel = await makeKernel()
    // 9 -> 10 -> "10" -> adapt String.count (2) -> increment -> 3
    let pipe = pipeline(increment)
        .map { "\($0)" }
        .pipe(increment) { $0.count }
        .seal()
    #expect(try await kernel.compose(pipe, 9) == 3)
}

// MARK: - dispatch (fire-and-forget, serial, error → sink)

/// Poll until `condition` holds, bounded so a stuck bus fails instead of hanging.
private func until(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw Boom()
}

@Test
func dispatchRunsCommandsSeriallyInSubmissionOrder() async throws {
    let probe = Probe()
    let record = Symbol<Int, Void>("test.record")
    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(record) { n in await probe.hit("c:\(n)") }
        return builder.build(buffer: BufferBuilder().build())
    }

    for n in 1...5 { kernel.dispatch(record, n) } // fire-and-forget, returns immediately
    try await until { await probe.hits.count == 5 }
    #expect(await probe.hits == ["c:1", "c:2", "c:3", "c:4", "c:5"])
}

@Test
func dispatchRoutesFailureToTheErrorSink() async throws {
    let probe = Probe()
    let boom = Symbol<Int, Void>("test.boom")
    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(boom) { _ -> Verb<Void> in .fail(Boom()) }
        return builder.build(buffer: BufferBuilder().build()) { error, symbol in
            await probe.hit("err:\(error):\(symbol)")
        }
    }

    kernel.dispatch(boom, 1)
    try await until { await probe.hits.count == 1 }
    #expect(await probe.hits.first == "err:Boom():test.boom")
}

// MARK: - trace (DEBUG: every invocation, including pipe internals)

@Test
func invokeRecordsSymbolAndVerbIntoTheTrace() async throws {
    let probe = Probe()
    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(increment) { $0 + 1 }
        builder.register(stringify) { "\($0)" }
        builder.register(guarded) { n -> Verb<Int> in n < 0 ? .fail(Boom()) : .next(n * 2) }
        return builder.build(
            buffer: BufferBuilder().build(),
            onTrace: { symbol, verb, _, _, _, _ in await probe.hit("\(symbol):\(verb.rawValue)") }
        )
    }

    _ = try await kernel.compose(pipeline(increment).pipe(stringify).seal(), 1) // both stages fire
    _ = try? await kernel.call(guarded, -1)                                     // Driver's .fail captured

    #expect(await probe.hits == [
        "test.increment:next",
        "test.stringify:next",
        "test.guarded:fail",
    ])
}

/// Collects the raw `(symbol, span, parent)` the trace sink emits, so a test can
/// assert the call tree the kernel rebuilds as data.
private actor TraceCollector {
    struct Record { let symbol: String; let span: UUID; let parent: UUID? }
    private(set) var records: [Record] = []
    func add(_ symbol: String, _ span: UUID, _ parent: UUID?) {
        records.append(Record(symbol: symbol, span: span, parent: parent))
    }
}

@Test
func invokeBuildsACallTreeFromSpanAndParent() async throws {
    // A composing handler that calls a leaf twice. The two leaves must come out
    // as children of the composing invoke (same parent = its span), and the
    // composing invoke itself as a flow root (parent == nil). Recording is
    // post-order, so children land before their parent.
    let parent = Symbol<Int, Int>("test.parent")
    let collector = TraceCollector()
    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(increment) { $0 + 1 }
        builder.register(parent) { (k: Kernel, n: Int) async throws -> Int in
            let a = try await k.call(increment, n)
            return try await k.call(increment, a)
        }
        return builder.build(
            buffer: BufferBuilder().build(),
            onTrace: { symbol, _, span, parent, _, _ in await collector.add(symbol, span, parent) }
        )
    }

    _ = try await kernel.call(parent, 1)

    let records = await collector.records
    #expect(records.map(\.symbol) == ["test.increment", "test.increment", "test.parent"]) // post-order
    let root = try #require(records.first { $0.symbol == "test.parent" })
    #expect(root.parent == nil)                                  // flow root
    let leaves = records.filter { $0.symbol == "test.increment" }
    #expect(leaves.allSatisfy { $0.parent == root.span })        // both children of the root
    #expect(Set(leaves.map(\.span)).count == 2)                  // distinct node identities
}

@Test
func concurrentCallsSeparateIntoDistinctRoots() async throws {
    // Two calls driven from independent child tasks interleave in the flat log
    // but must land in two different trees — each its own root, no cross-linking.
    let collector = TraceCollector()
    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(increment) { $0 + 1 }
        return builder.build(
            buffer: BufferBuilder().build(),
            onTrace: { symbol, _, span, parent, _, _ in await collector.add(symbol, span, parent) }
        )
    }

    async let a = kernel.call(increment, 1)
    async let b = kernel.call(increment, 2)
    _ = try await (a, b)

    let records = await collector.records
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.parent == nil })   // both are flow roots
    #expect(Set(records.map(\.span)).count == 2)        // distinct, unlinked trees
}

@Test
func forkBranchesAttachAsSiblingsUnderTheSharedParentSpan() async throws {
    // A composing handler that forks into two branches. `async let` inherits
    // the ambient `Kernel.span` at the point each child task is created — both
    // branches are declared while the root invoke's span is still bound, so
    // both branch leaves must land as siblings under that one root, not as
    // their own separate flow roots. Card 18's "要調査": does task-local
    // parent propagation already reach fork's concurrent children? Yes.
    let collector = TraceCollector()
    let branchA = Symbol<Int, Int>("test.fork.branchA")
    let branchB = Symbol<Int, Int>("test.fork.branchB")
    let root = Symbol<Int, (Int, Int)>("test.fork.root")

    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(branchA) { $0 * 2 }
        builder.register(branchB) { $0 * 3 }
        builder.register(root) { (k: Kernel, n: Int) async throws -> (Int, Int) in
            try await k.compose(
                pipeline(note: "identity") { (_, x: Int) -> Verb<Int> in .next(x) }
                    .fork(pipeline(branchA).seal(), pipeline(branchB).seal())
                    .seal(),
                n
            )
        }
        return builder.build(
            buffer: BufferBuilder().build(),
            onTrace: { symbol, _, span, parent, _, _ in await collector.add(symbol, span, parent) }
        )
    }

    let result = try await kernel.call(root, 5)
    #expect(result == (10, 15))

    let records = await collector.records
    let rootRecord = try #require(records.first { $0.symbol == "test.fork.root" })
    #expect(rootRecord.parent == nil) // the fork'd pipe's own flow root

    let branchRecords = records.filter { $0.symbol == "test.fork.branchA" || $0.symbol == "test.fork.branchB" }
    #expect(branchRecords.count == 2)
    #expect(branchRecords.allSatisfy { $0.parent == rootRecord.span }) // both siblings under root
    #expect(Set(branchRecords.map(\.span)).count == 2) // distinct node identities
}

@Test
func divertSplicesTheTargetPipesStagesAsSiblingsUnderTheSharedRootSpan() async throws {
    // A composing handler whose own pipe diverts mid-flight into another pipe.
    // `runStages` splices the diverted-to pipe's stages into the same loop
    // without rebinding `Kernel.span`, so the diverted-to pipe's own symbol
    // invokes must land as siblings under the *same* root span as the
    // diverting pipe's own stages — structurally indistinguishable from two
    // stages of one pipe. Card 25: the existing divert tests drove
    // `kernel.compose` directly with no enclosing invoke (`Kernel.span` nil
    // from the start), so this shared-root sibling shape was never verified.
    let collector = TraceCollector()
    let mainStage = Symbol<Int, Int>("test.divert.mainStage")
    let altStage = Symbol<Int, Int>("test.divert.altStage")
    let root = Symbol<Int, Int>("test.divert.root")

    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(mainStage) { $0 + 1 }
        builder.register(altStage) { $0 * 10 }
        builder.register(root) { (k: Kernel, n: Int) async throws -> Int in
            let alt = pipeline(altStage).seal()
            return try await k.compose(
                pipeline(mainStage)
                    .pipe { (_, x: Int) -> Verb<Int> in .divert(Diversion(alt, x)) }
                    .seal(),
                n
            )
        }
        return builder.build(
            buffer: BufferBuilder().build(),
            onTrace: { symbol, _, span, parent, _, _ in await collector.add(symbol, span, parent) }
        )
    }

    let result = try await kernel.call(root, 5)
    #expect(result == 60) // 5 -> +1 -> 6 -> divert -> *10 -> 60

    let records = await collector.records
    let rootRecord = try #require(records.first { $0.symbol == "test.divert.root" })
    #expect(rootRecord.parent == nil) // the diverting pipe's own flow root

    let mainRecord = try #require(records.first { $0.symbol == "test.divert.mainStage" })
    let altRecord = try #require(records.first { $0.symbol == "test.divert.altStage" })
    #expect(mainRecord.parent == rootRecord.span)
    #expect(altRecord.parent == rootRecord.span) // sibling, not nested under a new span
}

@Test
func traceStateRingTrimsToCapAndKeepsSequence() {
    var state = TraceState()
    let epoch = Date(timeIntervalSince1970: 0)
    for n in 0..<10 { state.record(symbol: "s\(n)", verb: .next, span: UUID(), parent: nil, payload: nil, at: epoch, cap: 3) }
    #expect(state.entries.map(\.symbol) == ["s7", "s8", "s9"]) // oldest dropped
    #expect(state.entries.map(\.id) == [7, 8, 9])              // monotonic seq survives trim
}

@Test
func traceStateTrimsInBatchesKeepingTheWindowWithinTheOvershoot() {
    var state = TraceState()
    let epoch = Date(timeIntervalSince1970: 0)
    let cap = 100
    var maxCount = 0
    for n in 0..<1000 {
        state.record(symbol: "s\(n)", verb: .next, span: UUID(), parent: nil, payload: nil, at: epoch, cap: cap)
        maxCount = max(maxCount, state.entries.count)
    }
    #expect(maxCount <= cap + cap / 4)   // never overshoots past cap × 1.25
    #expect(state.entries.count >= cap)  // a trim never cuts below cap
    #expect(state.entries.map(\.id) == Array((1000 - state.entries.count)..<1000)) // contiguous newest suffix
}

@Test
func bufferHistoryRingTrimsInBatchesKeepingTheWindowWithinTheOvershoot() {
    var state = BufferHistoryState()
    let epoch = Date(timeIntervalSince1970: 0)
    let cap = 100
    var maxCount = 0
    for _ in 0..<1000 {
        state.record(root: UUID(), stores: [], image: [:], at: epoch, cap: cap)
        maxCount = max(maxCount, state.snapshots.count)
    }
    #expect(maxCount <= cap + cap / 4)     // mirrors TraceState's batch trim
    #expect(state.snapshots.count >= cap)
    #expect(state.snapshots.map(\.id) == Array((1000 - state.snapshots.count)..<1000)) // contiguous newest suffix
}

// MARK: - forest (flat trace → call trees for the monitor)

@Test
func forestGroupsChildrenUnderTheirParentInCallOrder() {
    var state = TraceState()
    let t = Date(timeIntervalSince1970: 0)
    let root = UUID(), a = UUID(), b = UUID()
    // post-order: children record before their parent
    state.record(symbol: "a", verb: .next, span: a, parent: root, payload: nil, at: t, cap: 100)    // id 0
    state.record(symbol: "b", verb: .next, span: b, parent: root, payload: nil, at: t, cap: 100)    // id 1
    state.record(symbol: "root", verb: .next, span: root, parent: nil, payload: nil, at: t, cap: 100) // id 2

    let forest = state.forest
    #expect(forest.count == 1)
    #expect(forest[0].entry.symbol == "root")
    #expect(forest[0].children?.map { $0.entry.symbol } == ["a", "b"]) // ascending id = call order
    #expect(forest[0].children?.allSatisfy { $0.children == nil } == true) // leaves
    #expect(forest[0].children?.allSatisfy { $0.root == root } == true)    // tagged with the flow root
}

@Test
func forestSeparatesConcurrentFlowsNewestFirst() {
    var state = TraceState()
    let t = Date(timeIntervalSince1970: 0)
    state.record(symbol: "flowA", verb: .next, span: UUID(), parent: nil, payload: nil, at: t, cap: 100) // id 0
    state.record(symbol: "flowB", verb: .next, span: UUID(), parent: nil, payload: nil, at: t, cap: 100) // id 1

    let forest = state.forest
    #expect(forest.count == 2)
    #expect(forest.map { $0.entry.symbol } == ["flowB", "flowA"]) // highest id (newest) on top
}

@Test
func forestSurfacesAnEntryWithAnAbsentParentAsItsOwnRoot() {
    var state = TraceState()
    let t = Date(timeIntervalSince1970: 0)
    let missing = UUID(), child = UUID()
    // parent span never recorded — in-flight (root not yet recorded) or evicted
    state.record(symbol: "orphan", verb: .next, span: child, parent: missing, payload: nil, at: t, cap: 100)

    let forest = state.forest
    #expect(forest.count == 1)
    #expect(forest[0].entry.symbol == "orphan")
    #expect(forest[0].root == child) // its own span is the visible flow root
}

// MARK: - payload capture (DEBUG: opt-in via Kernel.recordsInspection)

/// Collects the rendered payload the trace sink emits per invoke.
private actor PayloadCollector {
    struct Record { let symbol: String; let payload: String? }
    private(set) var records: [Record] = []
    func add(_ symbol: String, _ payload: String?) { records.append(Record(symbol: symbol, payload: payload)) }
}

@Test
func describePayloadPrettyRendersAndCapsLength() {
    // `dump` renders a scalar leaf as "- <value>"; the trailing newline is dropped.
    #expect(Kernel.describePayload(42) == "- 42")
    #expect(Kernel.describePayload("hi") == "- \"hi\"")
    #expect(!Kernel.describePayload(42).contains("\n"))                   // no trailing blank line
    let long = String(repeating: "x", count: 50)
    let capped = Kernel.describePayload(long, cap: 10)
    #expect(capped.hasSuffix("…"))                                       // over cap: truncated
    #expect(capped.count == 11)                                          // 10 kept + the ellipsis
}

@Test
func invokeCapturesInputPayloadOnlyWhileTheToggleIsOn() async throws {
    // One test owns the global flag (set/reset here) so the off→nil assertion
    // can't race another test flipping it on.
    let collector = PayloadCollector()
    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(increment) { $0 + 1 }
        return builder.build(
            buffer: BufferBuilder().build(),
            onTrace: { symbol, _, _, _, payload, _ in await collector.add(symbol, payload) }
        )
    }

    Kernel.recordsInspection = false
    _ = try await kernel.call(increment, 41)   // off → not rendered

    Kernel.recordsInspection = true
    defer { Kernel.recordsInspection = false }
    _ = try await kernel.call(increment, 99)   // on → rendered

    let records = await collector.records
    #expect(records.map(\.payload) == [nil, "- 99"]) // dump renders the scalar leaf as "- 99"
}

// MARK: - run (forward-only, no return path)

@Test
func runDrivesForwardAndStopsOnAbortWithoutAnOutputType() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    let pipe = pipeline(increment)
        .effect { _, n in await probe.hit("eff:\(n)") }
        .pipe { _, n in n > 100 ? .abort(n) : .next(n) }
        .effect { _, n in await probe.hit("after:\(n)") }
        .seal()

    try await kernel.run(pipe, 5) // 6, eff:6, next, after:6
    #expect(await probe.hits == ["eff:6", "after:6"])

    try await kernel.run(pipe, 200) // 201, eff:201, abort -> stop
    #expect(await probe.hits == ["eff:6", "after:6", "eff:201"])
}

@Test
func runNeedsNoBoundaryCastSoAbortIsTypeFree() async throws {
    let kernel = await makeKernel()
    // `compose` on this pipe would throw composeTypeMismatch (Int abort, String output);
    // `run` discards the value, so there is no boundary cast and no throw.
    let pipe = pipeline(increment)
        .pipe { (_, _: Int) -> Verb<String> in .abort(999) }
        .seal()
    try await kernel.run(pipe, 0)
}

// MARK: - .abort

@Test
func abortStopsAndReturnsItsValue() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    let pipe = pipeline(increment)
        .pipe { _, n in n > 100 ? .abort(n) : .next(n) }
        .pipe { _, n in await probe.hit("downstream"); return .next(n) }
        .seal() // Pipe<Int, Int>

    let aborted = try await kernel.compose(pipe, 200) // 201 > 100 -> abort(201)
    #expect(aborted == 201)
    #expect(await probe.hits.isEmpty) // downstream never ran

    let passed = try await kernel.compose(pipe, 5) // 6 -> next -> downstream -> 6
    #expect(passed == 6)
    #expect(await probe.hits == ["downstream"])
}

// MARK: - .divert

@Test
func divertDiscardsRestAndRunsTheOtherPipe() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    let alt = pipeline(increment).pipe(increment).seal() // +2

    let main = pipeline(increment)
        .pipe { (_, _: Int) -> Verb<Int> in .divert(Diversion(alt, 1000)) }
        .pipe { _, n in await probe.hit("after-divert"); return .next(n) }
        .seal()

    let result = try await kernel.compose(main, 0) // diverted: 1000 -> +2 -> 1002
    #expect(result == 1002)
    #expect(await probe.hits.isEmpty) // post-divert stage discarded
}

@Test
func runAlsoDivertsWithoutReturningAValue() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    let alt = pipeline(note: "alt") { (_, n: Int) -> Verb<Int> in
        await probe.hit("alt:\(n)")
        return .next(n)
    }.seal()

    let main = pipeline(increment)
        .pipe { (_, _: Int) -> Verb<Int> in .divert(Diversion(alt, 999)) }
        .pipe { _, n in await probe.hit("after-divert"); return .next(n) }
        .seal()

    try await kernel.run(main, 0)
    #expect(await probe.hits == ["alt:999"]) // post-divert stage discarded here too
}

/// `loopStep` diverts back to a freshly-built one-stage pipe of itself
/// (PipelineA -> SwitchA -> PipelineA -> SwitchA -> ... -> abort) — a loop
/// built entirely from `.divert`, no dedicated loop construct. `compose` must
/// run this as *iteration* (swap the stage list, keep going), not as a nested
/// `compose` call per hop — otherwise a long-running agent/stream loop would
/// grow one async stack frame per hop and eventually choke. A high iteration
/// count here is the regression guard: if `.divert` ever goes back to
/// recursing, this either crashes or gets dramatically slower.
@Test
func divertLoopIsIterativeNotRecursive() async throws {
    let iterations = 100_000
    let loopStep = Symbol<Int, Int>("test.loopStep")
    let kernel = await MainActor.run { () -> Kernel in
        let builder = KernelBuilder()
        builder.register(loopStep) { n -> Verb<Int> in
            n >= iterations ? .abort(n) : .divert(Diversion(pipeline(loopStep).seal(), n + 1))
        }
        return builder.build(buffer: BufferBuilder().build())
    }

    let result = try await kernel.compose(pipeline(loopStep).seal(), 0)
    #expect(result == iterations)
}

// MARK: - .fail

private struct Boom: Error {}

@Test
func failThrowsOutOfCompose() async throws {
    let kernel = await makeKernel()
    let probe = Probe()
    let pipe = pipeline(increment)
        .pipe { (_, _: Int) -> Verb<Int> in .fail(Boom()) }
        .pipe { _, n in await probe.hit("downstream"); return .next(n) }
        .seal()

    await #expect(throws: Boom.self) {
        _ = try await kernel.compose(pipe, 0)
    }
    #expect(await probe.hits.isEmpty)
}

// MARK: - Terminator type mismatch is surfaced, not trapped

@Test
func abortWithWrongTypeThrowsTypeMismatch() async throws {
    let kernel = await makeKernel()
    // Output is String, but the rule aborts with an Int — caught at the boundary.
    let pipe = pipeline(increment)
        .pipe { (_, _: Int) -> Verb<String> in .abort(999) }
        .seal() // Pipe<Int, String>

    await #expect(throws: KernelError.self) {
        _ = try await kernel.compose(pipe, 0)
    }
}

// MARK: - Static shape (L1 descriptors)

@Test
func builtPipeExposesItsStaticShapeWithoutRunning() {
    // No kernel, no execution — building the pipe records each stage's descriptor,
    // so the wiring graph can read the topology back without running anything.
    let pipe = pipeline(increment)        // .pipe(symbol)  Int -> Int
        .pipe(stringify)                  // .pipe(symbol)  Int -> String
        .map { $0.count }                 // .map           String -> Int
        .seal()

    #expect(pipe.inputType == "Int")
    #expect(pipe.descriptors.map(\.kind) == [.pipe, .pipe, .map])
    #expect(pipe.descriptors.map(\.symbolID) == ["test.increment", "test.stringify", nil])
    #expect(pipe.descriptors.map(\.flows) == ["Int", "String", "Int"])
}

@Test
func tapAndVerbStagesAreLabelledInTheDescriptor() {
    let pipe = pipeline(increment)        // .pipe(symbol)  Int -> Int
        .tap(erase)                       // .tap(symbol)   side-effect, Int flows through
        .pipe { (_, n: Int) -> Verb<Int> in .next(n) } // .pipe { -> Verb } anonymous
        .seal()

    #expect(pipe.descriptors.map(\.kind) == [.pipe, .tap, .verb])
    #expect(pipe.descriptors.map(\.symbolID) == ["test.increment", "test.erase", nil])
}

@Test
func symbolDescriptionFlowsIntoTheDescriptor() {
    // A documented symbol carries its description; the pipe builder lifts it into
    // the stage descriptor (anonymous stages carry none).
    let documented = Symbol<Int, Int>("test.documented", description: "doubles the input")
    let pipe = pipeline(documented).map { $0 + 1 }.seal()

    #expect(pipe.descriptors.map(\.description) == ["doubles the input", nil])
}

@Test
func divertsToNamesCandidateTargetsOnAnonymousVerbStages() {
    // `.divert`'s actual target is runtime-decided and can't be derived, but an
    // author can name candidates for the wiring graph to render as jump links.
    let entry = pipeline(note: "maybe divert", divertsTo: ["Circuit.Slideshow.create"]) { (_, n: Int) -> Verb<Int> in .next(n) }
        .pipe(note: "maybe divert too", divertsTo: ["Circuit.Slideshow.open", "Circuit.Slideshow.delete"]) { (_, n: Int) -> Verb<Int> in .next(n) }
        .map { $0 + 1 } // .map never diverts — carries no divertsTo
        .seal()

    #expect(entry.descriptors.map(\.divertsTo) == [
        ["Circuit.Slideshow.create"],
        ["Circuit.Slideshow.open", "Circuit.Slideshow.delete"],
        [],
    ])
}
