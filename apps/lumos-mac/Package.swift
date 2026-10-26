// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lumos",
    defaultLocalization: "nl",
    // The inspector column and key presses need macOS 14.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lumos", targets: ["Lumos"]),
        // Hogsmeade, the playful face on the same lists and catalogue, builds on these.
        .library(name: "LumosCore", targets: ["LumosCore"]),
        .library(name: "LumosUI", targets: ["LumosUI"]),
    ],
    dependencies: [.package(path: "../../packages/burrow-kit")],
    targets: [
        // Everything testable without a window: the API, the browsing state
        // with focus and undo, and the trailer player's state.
        .target(name: "LumosCore", dependencies: [.product(name: "BurrowKit", package: "burrow-kit")]),
        // What both faces share on screen: artwork with its cache, the trailer
        // player, the menu commands and the control socket's commands.
        .target(name: "LumosUI", dependencies: ["LumosCore", .product(name: "BurrowUI", package: "burrow-kit")]),
        .executableTarget(
            name: "Lumos",
            dependencies: ["LumosCore", "LumosUI", .product(name: "BurrowUI", package: "burrow-kit")]),
        .testTarget(name: "LumosCoreTests", dependencies: ["LumosCore"]),
    ]
)
