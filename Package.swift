// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeSpat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NeSpat",
            path: "Sources/NeSpat"
        )
    ]
)
