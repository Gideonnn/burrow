// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hedwig",
    defaultLocalization: "nl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hedwig", targets: ["Hedwig"]),
    ],
    targets: [
        // Everything testable without a window: API client, models, app state.
        .target(name: "HedwigCore"),
        .executableTarget(name: "Hedwig", dependencies: ["HedwigCore"]),
        .testTarget(name: "HedwigCoreTests", dependencies: ["HedwigCore"]),
    ]
)
