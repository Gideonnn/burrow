// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pensieve",
    defaultLocalization: "nl",
    // The process tap that records the far end of a call needs macOS 14.2.
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "Pensieve", targets: ["Pensieve"]),
    ],
    dependencies: [.package(path: "../../packages/burrow-kit")],
    targets: [
        // Everything testable without a window or a microphone: the API,
        // the outbox of uploads, the iCloud copy, dictation's paste and the
        // RecHoarder import.
        .target(name: "PensieveCore", dependencies: ["PensieveMedia", .product(name: "BurrowKit", package: "burrow-kit")]),
        // Video on the Mac: sizes and presets, the H.264 encoder, audio
        // extraction and "Verklein video". AVFoundation predates Sendable,
        // hence Swift 5 mode.
        .target(name: "PensieveMedia", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The recorders: microphone plus a Core Audio process tap of
        // everything the Mac plays (from RecHoarder), the camera, the screen,
        // dictation and its hot key; Swift 5 mode, as it was written.
        .target(name: "PensieveCapture", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Pensieve",
            dependencies: ["PensieveCore", "PensieveCapture", "PensieveMedia", .product(name: "BurrowUI", package: "burrow-kit")]),
        .testTarget(name: "PensieveCoreTests", dependencies: ["PensieveCore", "PensieveMedia"]),
    ]
)
