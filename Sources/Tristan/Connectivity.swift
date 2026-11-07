import Foundation
import Network
import TristanCore

/// Reports whether the Mac has a route to the internet. Missions on a cloud provider fall back to Ollama while it does not.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private var started = false
    var onChange: ((Bool) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.onChange?(online) }
        }
        monitor.start(queue: DispatchQueue(label: "tristan.network", qos: .utility))
    }
}

/// Starts the local Ollama server by running the same `setup-ollama.sh` that sets it up, with `--start-only` so it
/// neither installs nor downloads anything (there is no internet when this is needed).
enum LocalModelLauncher {
    enum Outcome: Equatable {
        case ready
        case notInstalled
        case noModel
        case failed
    }

    /// The bundled copy inside the app, or the one in a source checkout when running from `swift run`.
    static func scriptURL() -> URL? {
        let fileManager = FileManager.default
        if let bundled = Bundle.main.url(forResource: "setup-ollama", withExtension: "sh") { return bundled }
        let checkout = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("scripts/setup-ollama.sh")
        return fileManager.fileExists(atPath: checkout.path) ? checkout : nil
    }

    static func start() async -> Outcome {
        if let models = await OllamaStatus.installedModels() { return models.isEmpty ? .noModel : await finish() }
        guard let script = scriptURL() else { return .failed }
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = try ProcessLauncher.prepare("/bin/bash", [script.path, "--start-only"], directory: nil, extraEnvironment: [:])
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: -1)
                }
            }
        }
        if status == 2 { return .notInstalled }
        guard status == 0 else { return .failed }
        return await finish()
    }

    private static func finish() async -> Outcome {
        guard let models = await OllamaStatus.installedModels() else { return .failed }
        return models.isEmpty ? .noModel : .ready
    }
}
