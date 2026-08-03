// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhonaApp",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic lives here so it can be tested without a running app, a microphone
        // or any granted permission.
        .target(
            name: "PhonaCore",
            path: "Sources/PhonaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PhonaApp",
            dependencies: ["PhonaCore"],
            path: "Sources/PhonaApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhonaCoreTests",
            dependencies: ["PhonaCore"],
            path: "Tests/PhonaCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
