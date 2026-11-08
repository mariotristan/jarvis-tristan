import ArgumentParser
import Foundation
import TristanCore

/// `tristan providers`: whether each provider could run a mission now.
struct ProvidersCommand: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "Show which providers are ready to run a mission.")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        for provider in CLIProvider.allCases {
            Terminal.writeOutput(Self.line(provider, problem: await Self.problem(provider)))
        }
        return .ok
    }

    static func line(_ provider: CLIProvider, problem: String?) -> String {
        let name = provider.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
        return name + (problem.map { "not ready: \(TerminalApprover.visible($0))" } ?? "ready") + "\n"
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
            if locate("aws") == nil { return "the AWS CLI was not found on PATH" }
            let region = (Settings.string("bedrock.region") ?? "").trimmingCharacters(in: .whitespaces)
            if !region.isEmpty && !BedrockStreamingClient.isValidRegion(region) {
                return "'\(region)' is not an AWS region (fix it with `tristan config set bedrock.region us-east-1`)"
            }
            return nil
        case .azure:
            func value(_ key: String) -> String { (Settings.string(key) ?? "").trimmingCharacters(in: .whitespaces) }
            if value("azure.endpoint").isEmpty || value("azure.deployment").isEmpty {
                return "set the endpoint and deployment first: `tristan config set azure.endpoint <url>` and "
                    + "`tristan config set azure.deployment <name>`"
            }
            // The provider also signs in with `az` (`az.cmd` on Windows). Checked first, so a present CLI avoids a
            // Keychain prompt on the Mac.
            if locate("az") != nil { return nil }
            if let key = KeychainStore.get(AzureConfig.keychainAccount), !key.isEmpty { return nil }
            return "no API key is stored and the Azure CLI (az) was not found "
                + "(store a key with `tristan secret set azure-openai-key`, or install the Azure CLI)"
        case .ollama:
            guard let installed = await OllamaStatus.installedModels() else {
                return "Ollama is not running (start it with `ollama serve`; if it listens elsewhere on this computer, "
                    + "`tristan config set ollama.host http://127.0.0.1:<port>`)"
            }
            let model = (Settings.string("ollama.model") ?? "").trimmingCharacters(in: .whitespaces)
            guard OllamaStatus.resolveModel(chosen: model, installed: installed) != nil else {
                return model.isEmpty ? "no model is installed (ollama pull llama3.1)"
                                     : "the model '\(model)' is not installed (ollama pull \(model), or choose an "
                                       + "installed one with `tristan config set ollama.model <name>`)"
            }
            return nil
        }
    }
}
