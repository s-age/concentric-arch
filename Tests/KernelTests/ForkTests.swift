import Foundation
import Testing
@testable import Kernel

// MARK: - Fixtures

private let identity = Symbol<Int, Int>("fork.identity")
private let double = Symbol<Int, Int>("fork.double")
private let square = Symbol<Int, Int>("fork.square")
private let stringify = Symbol<Int, String>("fork.stringify")
/// A verb-returning leaf: `.fail`s on a negative input, to drive fork's fail-fast path.
private let guarded = Symbol<Int, Int>("fork.guarded")
/// Sleeps, then reports whether it ran to completion or was cancelled mid-flight —
/// the probe into whether fork's fail-fast actually cancels the running sibling.
private let slow = Symbol<Int, Int>("fork.slow")

private struct Boom: Error {}

private actor Probe {
    private(set) var hits: [String] = []
    func hit(_ name: String) { hits.append(name) }
}

/// Poll until `condition` holds, bounded so a stuck task fails instead of hanging.
private func until(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw Boom()
}

@MainActor
private func makeKernel(probe: Probe) -> Kernel {
    let builder = KernelBuilder()
    builder.register(identity) { $0 }
    builder.register(double) { $0 * 2 }
    builder.register(square) { $0 * $0 }
    builder.register(stringify) { "\($0)" }
    builder.register(guarded) { n -> Verb<Int> in n < 0 ? .fail(Boom()) : .next(n) }
    builder.register(slow) { n in
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            await probe.hit("slow:cancelled")
            throw error
        }
        await probe.hit("slow:completed")
        return n
    }
    return builder.build(buffer: BufferBuilder().build())
}

// MARK: - Tuple overloads (2/3/4) — success, order preserved

@Test
func forkTwoRunsBranchesConcurrentlyAndPreservesOrder() async throws {
    let kernel = await makeKernel(probe: Probe())
    let pipe = pipeline(identity)
        .fork(pipeline(double).seal(), pipeline(stringify).seal())
        .seal()
    let (a, b) = try await kernel.compose(pipe, 3)
    #expect(a == 6)
    #expect(b == "3")
}

@Test
func forkThreeAndFourBuildHeterogeneousTuples() async throws {
    let kernel = await makeKernel(probe: Probe())

    let pipe3 = pipeline(identity)
        .fork(pipeline(double).seal(), pipeline(square).seal(), pipeline(stringify).seal())
        .seal()
    let (a, b, c) = try await kernel.compose(pipe3, 3)
    #expect(a == 6)
    #expect(b == 9)
    #expect(c == "3")

    let pipe4 = pipeline(identity)
        .fork(pipeline(double).seal(), pipeline(square).seal(), pipeline(stringify).seal(), pipeline(identity).seal())
        .seal()
    let (w, x, y, z) = try await kernel.compose(pipe4, 4)
    #expect(w == 8)
    #expect(x == 16)
    #expect(y == "4")
    #expect(z == 4)
}

@Test
func forkDescriptorNestsEachBranchsOwnStages() {
    let branchA = pipeline(double).pipe(stringify).seal() // 2 stages: double -> stringify
    let branchB = pipeline(square).seal() // 1 stage: square
    let pipe = pipeline(identity).fork(branchA, branchB).seal()

    let forkDescriptor = pipe.descriptors[1] // [0] identity leaf, [1] fork
    #expect(forkDescriptor.kind == .fork)
    #expect(forkDescriptor.branches.count == 2)
    #expect(forkDescriptor.branches[0].map(\.kind) == branchA.descriptors.map(\.kind))
    #expect(forkDescriptor.branches[0].map(\.symbolID) == branchA.descriptors.map(\.symbolID))
    #expect(forkDescriptor.branches[1].map(\.kind) == branchB.descriptors.map(\.kind))
    #expect(forkDescriptor.branches[1].map(\.symbolID) == branchB.descriptors.map(\.symbolID))
}

@Test
func forkOutputFlowsIntoMapWithoutADedicatedCombinator() async throws {
    let kernel = await makeKernel(probe: Probe())
    // The "transistor" is just `.map` reading the fork's tuple — no fork-specific join API.
    let pipe = pipeline(identity)
        .fork(pipeline(double).seal(), pipeline(square).seal())
        .map { a, b in a + b }
        .seal()
    #expect(try await kernel.compose(pipe, 3) == 15) // 6 + 9
}

// MARK: - Array overload — homogeneous, unbounded, order preserved

@Test
func forkArrayCollectsHomogeneousBranchesInOrder() async throws {
    let kernel = await makeKernel(probe: Probe())
    let pipe = pipeline(identity)
        .fork([pipeline(double).seal(), pipeline(square).seal(), pipeline(identity).seal()])
        .seal()
    let results = try await kernel.compose(pipe, 3)
    #expect(results == [6, 9, 3])
}

// MARK: - Fail-fast

@Test
func forkFailFastSkipsDownstreamOnBranchFailure() async throws {
    let probe = Probe()
    let kernel = await makeKernel(probe: probe)
    let pipe = pipeline(identity)
        .fork(pipeline(guarded).seal(), pipeline(double).seal())
        .effect { _, _ in await probe.hit("downstream") }
        .seal()
    await #expect(throws: Boom.self) {
        _ = try await kernel.compose(pipe, -1)
    }
    #expect(await probe.hits == [])
}

@Test
func forkFailFastCancelsTheStillRunningSibling() async throws {
    let probe = Probe()
    let kernel = await makeKernel(probe: probe)
    // `guarded` is awaited first and fails instantly; `slow` must never finish.
    let pipe = pipeline(identity)
        .fork(pipeline(guarded).seal(), pipeline(slow).seal())
        .seal()
    await #expect(throws: Boom.self) {
        _ = try await kernel.compose(pipe, -1)
    }
    try await until { await probe.hits.contains("slow:cancelled") }
    #expect(await probe.hits == ["slow:cancelled"])
}

@Test
func forkArrayFailFastCancelsTheStillRunningSiblings() async throws {
    let probe = Probe()
    let kernel = await makeKernel(probe: probe)
    // Same fail-fast/cancellation guarantee, but through the `withThrowingTaskGroup`
    // path (array overload) rather than `async let` (tuple overloads) — a distinct
    // code path that deserves its own proof.
    let pipe = pipeline(identity)
        .fork([pipeline(guarded).seal(), pipeline(slow).seal()])
        .seal()
    await #expect(throws: Boom.self) {
        _ = try await kernel.compose(pipe, -1)
    }
    try await until { await probe.hits.contains("slow:cancelled") }
    #expect(await probe.hits == ["slow:cancelled"])
}
