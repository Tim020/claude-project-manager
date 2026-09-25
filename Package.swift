// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SessionManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SessionManager", targets: ["SessionManager"]),
        .library(name: "SessionManagerCore", targets: ["SessionManagerCore"]),
    ],
    targets: [
        // Platform-independent logic: models, workspace operations, Claude Code
        // stream-json parsing, transcript building, persistence and process
        // orchestration. Builds and tests on Linux as well as macOS.
        .target(name: "SessionManagerCore"),

        // The SwiftUI macOS app. Sources are guarded with `#if os(macOS)` so the
        // package still builds on Linux CI.
        .executableTarget(
            name: "SessionManager",
            dependencies: ["SessionManagerCore"],
            resources: [.copy("Resources/Fonts")]
        ),

        .testTarget(
            name: "SessionManagerCoreTests",
            dependencies: ["SessionManagerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
