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
        // The same model, API, artwork cache and trailer player as Lumos:
        // Hogsmeade is another face on the same lists and catalogue.
        .package(name: "Lumos", path: "../lumos-mac"),
    ],
    targets: [
        .executableTarget(
            name: "Hogsmeade",
            dependencies: [
                .product(name: "LumosCore", package: "Lumos"),
                .product(name: "LumosUI", package: "Lumos"),
                .product(name: "BurrowUI", package: "burrow-kit"),
            ]),
    ]
)
