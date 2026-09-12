// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacbookDou",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HingeSensorKit",
            path: "Sources/HingeSensorKit"
        ),
        .executableTarget(
            name: "MacbookDou",
            dependencies: ["HingeSensorKit"],
            path: "Sources/MacbookDou",
            resources: [.process("Resources")]
        ),
    ]
)
