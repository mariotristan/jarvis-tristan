import ArgumentParser
import Foundation
import TristanCore

/// `tristan providers`: whether each provider could run a mission now.
struct ProvidersCommand: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "Show which providers are ready to run a mission.")

    func execute() async -> ExitCode {
        for provider in CLIProvider.allCases {
            Terminal.writeOutput(Self.line(provider, problem: await Self.problem(provider)))
        }
        return .ok
    }

    static func line(_ provider: CLIProvider, problem: String?) -> String {
        let name = provider.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
        return name + (problem.map { "not ready: \($0)" } ?? "ready") + "\n"
    }

    /// Why the provider cannot run, or nil when it looks ready. Checks presence only: logins are not verified.
    static func problem(_ provider: CLIProvider, locate: (String) -> String? = ProcessLauncher.locate) async -> String? {
        switch provider {
        case .claude:
            return locate("claude") == nil ? "the claude CLI was not found on PATH (install Claude Code)" : nil
        case .copilot:
            return locate("copilot") == nil ? "the copilot CLI was not found on PATH (npm install -g @github/copilot)" : nil
        case .bedrock:
            // Bedrock signs requests with credentials from the AWS CLI and falls back to `aws bedrock-runtime converse`.
            return locate("aws") == nil ? "the AWS CLI was not found on PATH" : nil
        case .azure:
            func value(_ key: String) -> String { (Settings.string(key) ?? "").trimmingCharacters(in: .whitespaces) }
            if value("azure.endpoint").isEmpty || value("azure.deployment").isEmpty {
                return "set azure.endpoint and azure.deployment first"
            }
            #if os(macOS)
            // On the Mac the provider also signs in with `az`. Checked first, so a present CLI avoids a Keychain prompt.
            if locate("az") != nil { return nil }
            #endif
            if let key = KeychainStore.get(AzureConfig.keychainAccount), !key.isEmpty { return nil }
            #if os(macOS)
            return "no API key is stored and the Azure CLI (az) was not found"
            #else
            return "no API key is stored"
            #endif
        case .ollama:
            guard let installed = await OllamaStatus.installedModels() else {
                return "Ollama is not running (start it with `ollama serve`)"
            }
            let model = (Settings.string("ollama.model") ?? "").trimmingCharacters(in: .whitespaces)
            guard OllamaStatus.resolveModel(chosen: model, installed: installed) != nil else {
                return model.isEmpty ? "no model is installed (ollama pull llama3.1)"
                                     : "the model '\(model)' is not installed (ollama pull \(model))"
            }
            return nil
        }
    }
}
