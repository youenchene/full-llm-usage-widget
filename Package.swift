// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FullLLMUsageWidget",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "UsageWidget",
            path: "Sources/UsageWidget"
        )
    ]
)
