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
        // The extracted kernel framework: Kernel + CallableMacros (`@callable`) +
        // the DEBUG tooling (KernelDebugUI / KernelDebugUISyntaxTools).
        // To develop against the local checkout instead of the tag:
        //   swift package edit swift-kernelee --path ../swift-kernelee   (undo: unedit)
        .package(url: "https://github.com/s-age/swift-kernelee.git", from: "0.1.0"),
    ],
    targets: [
        // Contract: ports (Symbol declarations) + model (entities/DTOs) + errors.
        // Imports CallableMacros: `@callable` is applied here, on the port protocols.
        .target(
            name: "Contract",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernelee"),
                .product(name: "CallableMacros", package: "swift-kernelee"),
            ],
            path: "Sources/Contract"
        ),
        // Infrastructure: storage device — repositories / stores / SwiftData @Model adapters.
        .target(name: "Infrastructure", dependencies: ["Contract"], path: "Sources/Infrastructure"),
        // Compute: computational device — pure business logic (no I/O, no kernel calls).
        .target(name: "Compute", dependencies: ["Contract"], path: "Sources/Compute"),
        // Circuit: orchestration device — routes between devices via the kernel (rules, no logic).
        .target(
            name: "Circuit",
            dependencies: [.product(name: "Kernel", package: "swift-kernelee"), "Contract"],
            path: "Sources/Circuit"
        ),
        // Driver: binds ports to concrete devices during wiring.
        .target(
            name: "Driver",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernelee"),
                "Contract", "Infrastructure", "Compute", "Circuit",
            ],
            path: "Sources/Driver"
        ),
        // Presentation: SwiftUI views + view models (talk only to Kernel + Contract).
        .target(
            name: "Presentation",
            dependencies: [.product(name: "Kernel", package: "swift-kernelee"), "Contract"],
            path: "Sources/Presentation"
        ),
        // App: the @main shell that wires every driver into the kernel.
        .executableTarget(
            name: "concentric-arch",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernelee"),
                .product(name: "KernelDebugUI", package: "swift-kernelee"),
                .product(name: "KernelDebugUISyntaxTools", package: "swift-kernelee"),
                "Contract", "Infrastructure", "Circuit", "Driver", "Presentation",
            ],
            path: "Sources/App"
        ),
        // WiringTests: exhaustiveness smoke tests over the real Driver manifest —
        // wires stub stores (keys only, never invoked) and cross-checks the derived
        // bound-symbol set against the hand-maintained WiringIntrospection registry,
        // and against the impl-location resolver (does this repo still follow the
        // default ImplSourceConventions the wiring graph runs with?).
        .testTarget(
            name: "WiringTests",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernelee"),
                .product(name: "KernelDebugUISyntaxTools", package: "swift-kernelee"),
                "Contract", "Circuit", "Driver",
            ],
            path: "Tests/WiringTests"
        ),
    ]
)
