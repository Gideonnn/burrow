// swift-tools-version:6.0
import PackageDescription

// What every Burrow app on the Mac shares: the server API, logging in,
// updates, the local task runner and the control socket agents use, plus the
// common SwiftUI screens (login, household, workers) and `burrowctl`.
let package = Package(
    name: "BurrowKit",
    defaultLocalization: "nl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BurrowKit", targets: ["BurrowKit"]),
        .library(name: "BurrowUI", targets: ["BurrowUI"]),
        .executable(name: "burrowctl", targets: ["burrowctl"]),
    ],
    targets: [
        .target(name: "BurrowKit"),
        .target(name: "BurrowUI", dependencies: ["BurrowKit"]),
        .executableTarget(name: "burrowctl", dependencies: ["BurrowKit"]),
        .testTarget(name: "BurrowKitTests", dependencies: ["BurrowKit"]),
        .testTarget(name: "BurrowUITests", dependencies: ["BurrowUI"]),
    ]
)
