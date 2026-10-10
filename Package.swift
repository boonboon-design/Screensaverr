// swift-tools-version:5.9
// Builds the UI-free core (networking, API clients, parsing) so it can be unit tested with
// `swift test`. The screen saver itself is built from Screensaverr.xcodeproj.
import PackageDescription

let package = Package(
    name: "ScreensaverrCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ScreensaverrCore", targets: ["ScreensaverrCore"]),
    ],
    targets: [
        .target(
            name: "ScreensaverrCore",
            path: "Screensaverr/Core"
        ),
        .testTarget(
            name: "ScreensaverrCoreTests",
            dependencies: ["ScreensaverrCore"],
            path: "Tests/ScreensaverrCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
