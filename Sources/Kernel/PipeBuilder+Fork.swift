import Foundation

// MARK: - Fork (parallel fan-out, `Promise.all`-style)

extension PipeBuilder {
    /// Fan the current value out to N independent branches (each a sealed sub
    /// `Pipe` run via `kernel.compose`), run them concurrently, and collect
    /// their results into an order-preserving tuple. `.map`/`.pipe` on the
    /// tuple output is the "transistor" that recombines the branches — no
    /// dedicated combinator is needed.
    ///
    /// Fail-fast via structured concurrency: `async let` cancels any
    /// not-yet-awaited sibling the moment this closure's scope exits (whether
    /// by returning or by throwing), so a failing branch stops the others
    /// without extra bookkeeping. `(try await r1, try await r2)` awaits
    /// left-to-right, so the propagated error is the first one *awaited*, not
    /// necessarily the first one that failed in wall-clock time.
    ///
    /// Requires `Sendable` on `Cursor` and every `Ri`: unlike the sequential
    /// stages in `PipeBuilder.swift`, this one actually crosses a concurrency
    /// boundary (`async let`), so Swift must be able to prove the values are
    /// safe to hand to a child task and back.
    public func fork<R1: Sendable, R2: Sendable>(
        _ b1: Pipe<Cursor, R1>,
        _ b2: Pipe<Cursor, R2>,
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, (R1, R2)> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "(\(R1.self), \(R2.self))", description: note, wireSite: SourceLocation(file: file, line: line), branches: [b1.descriptors, b2.descriptors]),
            run: { kernel, value in
                let cursor = value as! Cursor
                async let r1 = kernel.compose(b1, cursor)
                async let r2 = kernel.compose(b2, cursor)
                return .next((try await r1, try await r2))
            }
        ))
    }

    /// Three-branch overload — see the two-branch `fork` for the shared design notes.
    public func fork<R1: Sendable, R2: Sendable, R3: Sendable>(
        _ b1: Pipe<Cursor, R1>,
        _ b2: Pipe<Cursor, R2>,
        _ b3: Pipe<Cursor, R3>,
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, (R1, R2, R3)> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "(\(R1.self), \(R2.self), \(R3.self))", description: note, wireSite: SourceLocation(file: file, line: line), branches: [b1.descriptors, b2.descriptors, b3.descriptors]),
            run: { kernel, value in
                let cursor = value as! Cursor
                async let r1 = kernel.compose(b1, cursor)
                async let r2 = kernel.compose(b2, cursor)
                async let r3 = kernel.compose(b3, cursor)
                return .next((try await r1, try await r2, try await r3))
            }
        ))
    }

    /// Four-branch overload — see the two-branch `fork` for the shared design notes.
    public func fork<R1: Sendable, R2: Sendable, R3: Sendable, R4: Sendable>(
        _ b1: Pipe<Cursor, R1>,
        _ b2: Pipe<Cursor, R2>,
        _ b3: Pipe<Cursor, R3>,
        _ b4: Pipe<Cursor, R4>,
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, (R1, R2, R3, R4)> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "(\(R1.self), \(R2.self), \(R3.self), \(R4.self))", description: note, wireSite: SourceLocation(file: file, line: line), branches: [b1.descriptors, b2.descriptors, b3.descriptors, b4.descriptors]),
            run: { kernel, value in
                let cursor = value as! Cursor
                async let r1 = kernel.compose(b1, cursor)
                async let r2 = kernel.compose(b2, cursor)
                async let r3 = kernel.compose(b3, cursor)
                async let r4 = kernel.compose(b4, cursor)
                return .next((try await r1, try await r2, try await r3, try await r4))
            }
        ))
    }

    /// Homogeneous, unbounded fan-out: same branch type repeated N times,
    /// collected into an order-preserving array. Escape hatch for arities
    /// beyond the tuple overloads above (2...4) or a true variable-length
    /// fan-out. `async let` can't express a dynamic arity, so this uses
    /// `withThrowingTaskGroup` instead — each child tags its result with its
    /// index so the array can be reassembled in submission order regardless
    /// of completion order. A child's throw cancels the rest of the group and
    /// propagates once the group finishes unwinding (the same structured-
    /// concurrency guarantee the tuple overloads get from `async let`).
    public func fork<R: Sendable>(
        _ branches: [Pipe<Cursor, R>],
        note: String? = nil,
        file: String = #filePath,
        line: Int = #line
    ) -> PipeBuilder<Input, [R]> where Cursor: Sendable {
        appending(PipeStage(
            descriptor: StageDescriptor(kind: .fork, symbolID: nil, flows: "[\(R.self)]", description: note, wireSite: SourceLocation(file: file, line: line), branches: branches.map(\.descriptors)),
            run: { kernel, value in
                let cursor = value as! Cursor
                let results = try await withThrowingTaskGroup(of: (Int, R).self) { group -> [R] in
                    for (index, branch) in branches.enumerated() {
                        group.addTask { (index, try await kernel.compose(branch, cursor)) }
                    }
                    var collected = [R?](repeating: nil, count: branches.count)
                    for try await (index, result) in group {
                        collected[index] = result
                    }
                    return collected.map { $0! }
                }
                return .next(results)
            }
        ))
    }
}
