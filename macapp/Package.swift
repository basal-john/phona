// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhonaApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhonaApp",
            path: "Sources/PhonaApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
