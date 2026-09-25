// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Claudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudio", targets: ["Claudio"]),
        .library(name: "ClaudioCore", targets: ["ClaudioCore"]),
    ],
    dependencies: [
        // Terminal emulator for each session's interactive `claude`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        // Platform-independent logic: models, workspace operations, Claude Code
        // hook events and history, terminal launch commands, persistence and
        // AppModel. Builds and tests on Linux as well as macOS.
        .target(name: "ClaudioCore"),

        // The SwiftUI macOS app. Sources are guarded with `#if os(macOS)` so the
        // package still builds on Linux CI.
        .executableTarget(
            name: "Claudio",
            dependencies: [
                "ClaudioCore",
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
            ],
            resources: [.copy("Resources/Fonts")]
        ),

        .testTarget(
            name: "ClaudioCoreTests",
            dependencies: ["ClaudioCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
