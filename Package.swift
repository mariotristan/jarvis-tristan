// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tristan",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // The portable core: agent loop, providers, approval policy, memory and history. Everything built on `Process`
        // or sockets lives in Sources/TristanCore/Processes (the iOS project compiles the rest by path).
        .target(
            name: "TristanCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows, .linux]))],
            path: "Sources/TristanCore"
        ),
        .testTarget(name: "TristanCoreTests", dependencies: ["TristanCore"], path: "Tests/TristanCoreTests"),
    ]
)

// The Mac app needs AppKit, so it (and its tests) only exist on macOS; other toolchains build just the core.
#if os(macOS)
package.targets += [
    .executableTarget(name: "Tristan", dependencies: ["TristanCore"], path: "Sources/Tristan"),
    .testTarget(name: "TristanTests", dependencies: ["Tristan", "TristanCore"], path: "Tests/TristanTests"),
]
#endif
