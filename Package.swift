// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacbookDuo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HingeSensorKit",
            path: "Sources/HingeSensorKit"
        ),
        .executableTarget(
            name: "MacbookDuo",
            dependencies: ["HingeSensorKit"],
            path: "Sources/MacbookDuo",
            resources: [.process("Resources")]
        ),
    ]
)
