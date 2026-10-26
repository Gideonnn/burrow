// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hedwig",
    defaultLocalization: "nl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hedwig", targets: ["Hedwig"]),
        .executable(name: "hedwigctl", targets: ["hedwigctl"]),
        // Hogsmeade builds on the same outing types, status sentences and ticket readers.
        .library(name: "HedwigCore", targets: ["HedwigCore"]),
    ],
    dependencies: [.package(path: "../../packages/burrow-kit")],
    targets: [
        // Everything testable without a window: mail API, models, app state.
        .target(name: "HedwigCore", dependencies: [.product(name: "BurrowKit", package: "burrow-kit")]),
        .executableTarget(
            name: "Hedwig",
            dependencies: ["HedwigCore", .product(name: "BurrowUI", package: "burrow-kit")]),
        // `burrowctl hedwig …` under its old name.
        .executableTarget(name: "hedwigctl", dependencies: [.product(name: "BurrowKit", package: "burrow-kit")]),
        .testTarget(name: "HedwigCoreTests", dependencies: ["HedwigCore"]),
    ]
)
