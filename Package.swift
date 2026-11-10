// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeSpat",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.2.2")
    ],
    targets: [
        .executableTarget(
            name: "NeSpat",
            dependencies: [
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess")
            ],
            path: "Sources/NeSpat"
        )
    ]
)
