// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VfixApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VfixApp",
            path: "Sources/VfixApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
