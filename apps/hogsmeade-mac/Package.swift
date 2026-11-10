// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hogsmeade",
    defaultLocalization: "nl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hogsmeade", targets: ["Hogsmeade"]),
    ],
    dependencies: [
        .package(path: "../../packages/burrow-kit"),
    ],
    targets: [
        .target(name: "HogsmeadeCore", dependencies: [.product(name: "BurrowKit", package: "burrow-kit")]),
        // The views that are not one screen: pictures, the map, ticket codes,
        // the new-outing sheet, the menu bar and the burrowctl commands.
        .target(
            name: "HogsmeadeUI",
            dependencies: ["HogsmeadeCore", .product(name: "BurrowUI", package: "burrow-kit")]),
        .executableTarget(
            name: "Hogsmeade",
            dependencies: ["HogsmeadeCore", "HogsmeadeUI", .product(name: "BurrowUI", package: "burrow-kit")]),
        .testTarget(name: "HogsmeadeCoreTests", dependencies: ["HogsmeadeCore"]),
    ]
)
