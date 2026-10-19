// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hedwig",
    defaultLocalization: "nl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hedwig", targets: ["Hedwig"]),
        .executable(name: "hedwigctl", targets: ["hedwigctl"]),
    ],
    targets: [
        // Everything testable without a window: API client, models, app state.
        .target(name: "HedwigCore"),
        .executableTarget(name: "Hedwig", dependencies: ["HedwigCore"]),
        // Lets agents on this Mac read and operate the running app.
        .executableTarget(name: "hedwigctl", dependencies: ["HedwigCore"]),
        .testTarget(name: "HedwigCoreTests", dependencies: ["HedwigCore"]),
    ]
)
