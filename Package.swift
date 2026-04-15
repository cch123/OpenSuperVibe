// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SuperVibe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SuperVibe",
            path: "Sources/SuperVibe",
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
