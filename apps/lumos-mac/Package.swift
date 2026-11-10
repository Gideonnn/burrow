// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Lumos",
    defaultLocalization: "nl",
    // Drawn as macOS 26 draws SwiftUI: Liquid Glass, glass buttons on the artwork.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Lumos", targets: ["Lumos"]),
        // Library products, so another face or tool can build on the model and the shared views.
        .library(name: "LumosCore", targets: ["LumosCore"]),
        .library(name: "LumosUI", targets: ["LumosUI"]),
    ],
    dependencies: [.package(path: "../../packages/burrow-kit")],
    targets: [
        // Everything testable without a window: the API, the browsing state
        // with focus and undo, and the trailer player's state.
        .target(name: "LumosCore", dependencies: [.product(name: "BurrowKit", package: "burrow-kit")]),
        // What the screens share: artwork with its cache, the trailer
        // player, the menu commands and the control socket's commands.
        .target(name: "LumosUI", dependencies: ["LumosCore", .product(name: "BurrowUI", package: "burrow-kit")]),
        .executableTarget(
            name: "Lumos",
            dependencies: ["LumosCore", "LumosUI", .product(name: "BurrowUI", package: "burrow-kit")]),
        .testTarget(name: "LumosCoreTests", dependencies: ["LumosCore"]),
    ]
)
