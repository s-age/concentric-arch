// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConcentricArch",
    platforms: [.macOS(.v15)],
    products: [
        // The `concentric-arch` executable bundles every layer
        // (Kernel/Contract/Infrastructure/Compute/Circuit/Driver/Presentation) plus
        // the SwiftUI @main shell in App/. The build script (Scripts/build.sh) copies the
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
        // Compute: computational device — pure business logic (no I/O, no kernel calls).
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
