// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hogsmeade",
    defaultLocalization: "nl",
    platforms: [.macOS(.v14)],
    products: [
        // The two faces: the native window and the playful one.
        .executable(name: "Hogsmeade", targets: ["Hogsmeade"]),
        .executable(name: "HogsmeadeFeest", targets: ["HogsmeadeFeest"]),
    ],
    dependencies: [
        .package(path: "../../packages/burrow-kit"),
        // The outings themselves are Hedwig's: the same types, status sentences,
        // Dutch dates, place book and ticket code readers.
        .package(name: "Hedwig", path: "../hedwig-mac"),
    ],
    targets: [
        .target(
            name: "HogsmeadeCore",
            dependencies: [
                .product(name: "HedwigCore", package: "Hedwig"),
                .product(name: "BurrowKit", package: "burrow-kit"),
            ]),
        // What both faces share on screen: pictures, the map, ticket codes,
        // the new-outing sheet and confetti.
        .target(
            name: "HogsmeadeUI",
            dependencies: ["HogsmeadeCore", .product(name: "BurrowUI", package: "burrow-kit")]),
        .executableTarget(
            name: "Hogsmeade",
            dependencies: ["HogsmeadeCore", "HogsmeadeUI", .product(name: "BurrowUI", package: "burrow-kit")]),
        .executableTarget(
            name: "HogsmeadeFeest",
            dependencies: ["HogsmeadeCore", "HogsmeadeUI", .product(name: "BurrowUI", package: "burrow-kit")]),
        .testTarget(name: "HogsmeadeCoreTests", dependencies: ["HogsmeadeCore"]),
    ]
)
