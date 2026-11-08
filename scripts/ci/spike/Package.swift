// swift-tools-version: 5.9
// Throwaway diagnostics for the Windows bring-up (plan Task 0), run by the `windows-spike` CI job. Not part of the app.
import PackageDescription

let package = Package(
    name: "Spike",
    targets: [
        // Prints exactly what it received: each argument JSON-escaped, and on Windows the raw command line.
        .executableTarget(name: "argdump", path: "Sources/argdump"),
        // Starts a program with Foundation.Process, optionally followed by a fixed set of awkward arguments.
        .executableTarget(name: "launch", path: "Sources/launch"),
        // Streams a URL with a URLSession data delegate and prints when each chunk and line arrived.
        .executableTarget(name: "stream-client", path: "Sources/stream-client"),
    ]
)
