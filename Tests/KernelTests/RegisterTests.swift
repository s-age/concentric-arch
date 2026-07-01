import Foundation
import Testing
@testable import Kernel

// MARK: - Duplicate registration

/// Registering the same symbol id twice must trap at the second `register`,
/// not silently last-write-win — *which handler answers a symbol* is the
/// runtime half of the architecture's guarantee, and the kernel must defend
/// it on its own (the Callable-layer collision check is app-side and won't
/// travel with the extracted framework). Exit tests spawn a child process, so
/// the `precondition` failure is observed rather than taking the suite down.
@Test func duplicateRegisterTrapsAtTheSecondBind() async {
    await #expect(processExitsWith: .failure) {
        let symbol = Symbol<Int, Int>("test.duplicate")
        let builder = KernelBuilder()
        builder.register(symbol) { $0 + 1 }
        builder.register(symbol) { $0 + 2 }
    }
}

/// All four `register` overloads funnel through the same write point, so a
/// duplicate traps regardless of which overload pair collides — here the
/// kernel-taking and verb-returning shapes against a plain leaf.
@Test func duplicateRegisterTrapsAcrossOverloads() async {
    await #expect(processExitsWith: .failure) {
        let symbol = Symbol<Int, Int>("test.duplicate.overloads")
        let builder = KernelBuilder()
        builder.register(symbol) { $0 * 2 }
        builder.register(symbol) { (n: Int) -> Verb<Int> in .next(n) }
    }
}

/// Distinct ids coexist — the guard fires on *collision*, not on volume.
@MainActor
@Test func distinctSymbolsRegisterFreely() {
    let builder = KernelBuilder()
    builder.register(Symbol<Int, Int>("test.register.a")) { $0 }
    builder.register(Symbol<Int, Int>("test.register.b")) { $0 }
    #expect(builder.boundSymbolIDs == ["test.register.a", "test.register.b"])
}
