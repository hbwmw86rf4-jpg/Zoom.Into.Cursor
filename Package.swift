// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "5KLens",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LensApp",
            path: "Sources"
        )
    ]
)
