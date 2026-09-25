// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SessionManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SessionManager", targets: ["SessionManager"]),
        .library(name: "SessionManagerCore", targets: ["SessionManagerCore"]),
    ],
    dependencies: [
        // Terminal emulator for each session's interactive `claude`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        // Platform-independent logic: models, workspace operations, Claude Code
        // hook events and history, terminal launch commands, persistence and
        // AppModel. Builds and tests on Linux as well as macOS.
        .target(name: "SessionManagerCore"),

        // The SwiftUI macOS app. Sources are guarded with `#if os(macOS)` so the
        // package still builds on Linux CI.
        .executableTarget(
            name: "SessionManager",
            dependencies: [
                "SessionManagerCore",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
            ],
            resources: [.copy("Resources/Fonts")]
        ),

        .testTarget(
            name: "SessionManagerCoreTests",
            dependencies: ["SessionManagerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
