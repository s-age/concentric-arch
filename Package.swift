// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport

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
    dependencies: [
        // swift-syntax backs the `@callable` macro plugin (compile-time wiring generation).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        // CallableMacrosPlugin: compiler plugin implementing `@callable` — generates
        // typed Symbols + wiring from a device protocol's method requirements.
        .macro(
            name: "CallableMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/CallableMacrosPlugin"
        ),
        // Kernel: the dispatch primitives (`Symbol`, `Kernel`, `KernelBuilder`). Leaf.
        .target(name: "Kernel", path: "Sources/Kernel"),
        // Contract: ports (Symbol declarations) + model (entities/DTOs) + errors.
        // Depends on the macro plugin: `@callable` is declared and used here.
        .target(name: "Contract", dependencies: ["Kernel", "CallableMacrosPlugin"], path: "Sources/Contract"),
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
        // KernelDebugUI: the DEBUG-only kernel monitor + wiring graph. Framework
        // tooling, not an app device — depends on Kernel alone (all data arrives
        // via injection from the composition root), so it extracts with the kernel.
        .target(name: "KernelDebugUI", dependencies: ["Kernel"], path: "Sources/KernelDebugUI"),
        // KernelDebugUISyntaxTools: the structural (SwiftSyntax) impl-location
        // resolver behind the wiring graph's "open the implementation" jump.
        // Deliberately a separate target: SwiftPM has no per-configuration
        // dependencies, so this is the only way a framework consumer who doesn't
        // need impl jumps can avoid resolving/linking swift-syntax at all
        // (wire-site jumps are `#filePath`/`#line` captures — no parser needed).
        .target(
            name: "KernelDebugUISyntaxTools",
            dependencies: [
                "Kernel",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/KernelDebugUISyntaxTools"
        ),
        // App: the @main shell that wires every driver into the kernel.
        .executableTarget(
            name: "concentric-arch",
            dependencies: [
                "Kernel", "Contract", "Infrastructure", "Circuit", "Driver", "Presentation",
                "KernelDebugUI", "KernelDebugUISyntaxTools",
            ],
            path: "Sources/App"
        ),
        // Tests for the dispatch primitives — the load-bearing `compose` pipeline.
        .testTarget(name: "KernelTests", dependencies: ["Kernel"], path: "Tests/KernelTests"),
        // DebugToolingTests: the impl-location resolver checked against this repo's
        // real sources (every Callable symbol must resolve to its `func` line).
        .testTarget(
            name: "DebugToolingTests",
            dependencies: ["Kernel", "Contract", "KernelDebugUISyntaxTools"],
            path: "Tests/DebugToolingTests"
        ),
        // WiringTests: exhaustiveness smoke tests over the real Driver manifest —
        // wires stub stores (keys only, never invoked) and cross-checks the derived
        // bound-symbol set against the hand-maintained WiringIntrospection registry.
        .testTarget(
            name: "WiringTests",
            dependencies: ["Kernel", "Contract", "Circuit", "Driver"],
            path: "Tests/WiringTests"
        ),
    ]
)
