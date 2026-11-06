// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tristan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Tristan", path: "Sources/Tristan"),
        .testTarget(name: "TristanTests", dependencies: ["Tristan"], path: "Tests/TristanTests"),
    ]
)
