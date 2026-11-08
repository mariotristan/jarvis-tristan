// swift-tools-version: 5.9
import PackageDescription

// The command-line tool is `tristan`. On the Mac it is built as `tristan-cli`, because a case-insensitive APFS volume
// cannot hold both `tristan` and the app's `Tristan` binary in the same build folder.
#if os(macOS)
let cliProduct = "tristan-cli"
#else
let cliProduct = "tristan"
#endif

let package = Package(
    name: "Tristan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: cliProduct, targets: ["TristanCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
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
        // The `tristan` command. All of its logic lives in TristanCLICore so tests can import it; TristanCLI is only
        // the entry point.
        .target(
            name: "TristanCLICore",
            dependencies: ["TristanCore", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/TristanCLICore"
        ),
        .executableTarget(name: "TristanCLI", dependencies: ["TristanCLICore"], path: "Sources/TristanCLI"),
        // Not on the executable target: some Windows toolchains cannot link one into a test bundle.
        .testTarget(name: "TristanCLITests", dependencies: ["TristanCLICore", "TristanCore"],
                    path: "Tests/TristanCLITests"),
    ]
)

// The Mac app needs AppKit, so it (and its tests) only exist on macOS; other toolchains build just the core.
#if os(macOS)
package.targets += [
    .executableTarget(name: "Tristan", dependencies: ["TristanCore"], path: "Sources/Tristan"),
    .testTarget(name: "TristanTests", dependencies: ["Tristan", "TristanCore"], path: "Tests/TristanTests"),
]
#endif
