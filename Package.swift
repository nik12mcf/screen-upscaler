// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenUpscaler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenUpscaler",
            path: "Sources/ScreenUpscaler",
            // The scaffold uses the Swift 5 concurrency model so the capture
            // callback can hand frames to the renderer without ceremony.
            // Tightening this to .v6 is a good first refactor - see README.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
