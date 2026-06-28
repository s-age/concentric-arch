// swift-tools-version: 6.0
import PackageDescription

// ConcentricArch — a kernel-centric, forward-only concentric architecture.
// Overview & diagram: https://github.com/s-age/concentric-arch#readme
//
// The single inward direction this project claims is not just prose — the
// compiler enforces it on two axes that meet at one point:
//
//   • Dependency. The target graph below *is* the enforcement: a target can
//     only `import` a module listed in its `dependencies`, so a back-edge
//     (Kernel reaching for Presentation, Compute for Infrastructure, …) fails
//     to compile. Inner targets stay leaves; `concentric-arch` (App) is the
//     only root that sees everything.
//
//   • Execution. Messages flow forward through phantom-typed `Symbol<P, O>`
//     and the `Pipe` builder, whose chain constraint ("previous Return == next
//     Payload") is checked at compile time. There is no return path.
//
// Dependency injection is used at the seams — Drivers bind handlers into the
// `KernelBuilder`, and the kernel is handed to composing handlers at call time
// — but it opens no hole in either axis: the same `Symbol` pins both ends, so
// the dynamic wiring still resolves to the one compiler-checked direction.

let package = Package(
    name: "ConcentricArch",
    platforms: [.macOS(.v15)],
    products: [
        // The `concentric-arch` executable bundles every layer
        // (Presentation/UseCase/Domain/Repository/Infrastructure) plus the
        // SwiftUI @main shell in App/. The build script (Scripts/build.sh) copies the
        // resulting `.build/release/concentric-arch` binary into concentric-arch.app.
        .executable(name: "concentric-arch", targets: ["concentric-arch"]),
    ],
    targets: [
        // Kernel: the dispatch primitives (`Symbol`, `Kernel`, `KernelBuilder`). Leaf.
        .target(name: "Kernel", path: "Sources/Kernel"),
        // Contract: ports (Symbol declarations) + model (entities/DTOs) + errors.
        .target(name: "Contract", dependencies: ["Kernel"], path: "Sources/Contract"),
        // Infrastructure: storage device — repositories / stores / SwiftData @Model adapters.
        .target(name: "Infrastructure", dependencies: ["Contract"], path: "Sources/Infrastructure"),
        // Compute: computational device — pure domain logic (no I/O, no kernel calls).
        .target(name: "Compute", dependencies: ["Contract"], path: "Sources/Compute"),
        // Circuit: orchestration device — routes between devices via the kernel (rules, no logic).
        .target(name: "Circuit", dependencies: ["Kernel", "Contract"], path: "Sources/Circuit"),
        // Driver: binds ports to concrete devices during wiring.
        .target(
            name: "Driver",
            dependencies: ["Kernel", "Contract", "Infrastructure", "Compute", "Circuit"],
            path: "Sources/Driver"
        ),
        // Presentation: SwiftUI views + view models (talk only to Kernel + Contract).
        .target(name: "Presentation", dependencies: ["Kernel", "Contract"], path: "Sources/Presentation"),
        // App: the @main shell that wires every driver into the kernel.
        .executableTarget(
            name: "concentric-arch",
            dependencies: ["Kernel", "Contract", "Infrastructure", "Circuit", "Driver", "Presentation"],
            path: "Sources/App"
        ),
        // Tests for the dispatch primitives — the load-bearing `compose` pipeline.
        .testTarget(name: "KernelTests", dependencies: ["Kernel"], path: "Tests/KernelTests"),
    ]
)
