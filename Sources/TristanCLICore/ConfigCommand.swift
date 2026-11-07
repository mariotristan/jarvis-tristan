import ArgumentParser
import Foundation
import TristanCore

/// One provider setting `tristan config` may change: a key the providers read through `Settings`.
struct ConfigKey {
    let name: String
    /// What applies when nothing is set, as shown by `list` and printed by `get`; nil when there is none.
    let defaultValue: String?
    /// Shown by `list` when there is no default value.
    let unsetMeaning: String
    /// Why `value` (already trimmed, no control characters) is refused, or nil when it is fine.
    let problem: (String) -> String?

    /// The allowlist. These are exactly the provider keys the core and the Mac app's Configuration read; anything else
    /// (`kidsMode`, `allowRules`, ...) is refused so the terminal cannot switch off kids mode or grant approvals.
    static let all: [ConfigKey] = [
        ConfigKey(name: "ollama.host", defaultValue: OllamaConfig.defaultHost, unsetMeaning: "") {
            OllamaConfig.isAllowedHost($0) ? nil
                : "Ollama must run on this computer: an http URL on localhost, 127.0.0.1 or ::1, for example \(OllamaConfig.defaultHost)."
        },
        ConfigKey(name: "ollama.model", defaultValue: nil, unsetMeaning: "the first installed model", problem: modelName),
        ConfigKey(name: "azure.endpoint", defaultValue: nil, unsetMeaning: "required for Azure OpenAI") {
            AzureConfig.isAllowedEndpoint($0) ? nil
                : "The endpoint must be an https Azure OpenAI URL, like https://my-resource.openai.azure.com."
        },
        ConfigKey(name: "azure.deployment", defaultValue: nil, unsetMeaning: "required for Azure OpenAI") {
            AzureConfig.isValidDeployment($0) ? nil
                : "The deployment name may only contain letters, digits, dots, dashes and underscores."
        },
        ConfigKey(name: "azure.apiVersion", defaultValue: AzureConfig.defaultAPIVersion, unsetMeaning: "") {
            $0.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}(-preview)?\z"#, options: .regularExpression) != nil ? nil
                : "The API version looks like \(AzureConfig.defaultAPIVersion) or 2025-01-01-preview."
        },
        ConfigKey(name: "bedrock.region", defaultValue: BedrockConfig.defaultRegion, unsetMeaning: "") {
            BedrockStreamingClient.isValidRegion($0) ? nil : "That is not an AWS region name, like us-east-1 or eu-west-2."
        },
        ConfigKey(name: "bedrock.model", defaultValue: BedrockConfig.defaultModel, unsetMeaning: "", problem: modelName),
        ConfigKey(name: "bedrock.profile", defaultValue: nil, unsetMeaning: "the AWS CLI default profile") {
            $0.range(of: #"\A[A-Za-z0-9_.@+][A-Za-z0-9_.@+-]*\z"#, options: .regularExpression) != nil ? nil
                : "A profile name may only contain letters, digits and _ . @ + - (and may not start with -)."
        },
        ConfigKey(name: "copilot.model", defaultValue: nil, unsetMeaning: "the Copilot CLI's default model", problem: modelName),
    ]

    /// Model names and Bedrock model IDs or ARNs: no spaces, and never something a CLI could read as an option.
    static func modelName(_ value: String) -> String? {
        value.range(of: #"\A[A-Za-z0-9_.:/@+][A-Za-z0-9_.:/@+-]*\z"#, options: .regularExpression) != nil ? nil
            : "A model name may only contain letters, digits and _ . : / @ + - (and may not start with -)."
    }

    static func named(_ name: String) -> ConfigKey? { all.first { $0.name == name } }

    /// The key, or nil after printing the keys that can be set (a usage error).
    static func lookup(_ name: String) -> ConfigKey? {
        if let key = named(name) { return key }
        _ = Kids.refuse("'\(TerminalApprover.visible(name))' is not a setting tristan can change. Settings: "
                        + all.map(\.name).joined(separator: ", ") + ".")
        return nil
    }

    /// The trimmed value, or nil (after printing why) when it is empty, has a control character or fails validation.
    func accept(_ raw: String) -> String? {
        if raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) {
            _ = Kids.refuse("The value may not contain line breaks or control characters. Nothing was changed.")
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            _ = Kids.refuse("The value is empty. Use `tristan config unset \(name)` to go back to the default. Nothing was changed.")
            return nil
        }
        if let problem = problem(value) {
            _ = Kids.refuse(problem + " Nothing was changed.")
            return nil
        }
        return value
    }

    /// What is stored now (a non-text value, e.g. from a hand-edited settings file, counts as not set).
    var stored: String? { Settings.string(name) }
}

/// `tristan config list|get|set|unset`: the provider settings, for computers without the Mac app's Configuration window.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change provider settings (models, endpoints, regions). Secrets go through `tristan secret`.",
        subcommands: [ConfigList.self, ConfigGet.self, ConfigSet.self, ConfigUnset.self])
}

struct ConfigList: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Show every setting, its value and its default.")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        let width = (ConfigKey.all.map(\.name.count).max() ?? 0) + 2
        for key in ConfigKey.all {
            let value = key.stored.map(TerminalApprover.visible) ?? "(not set)"
            let fallback = key.defaultValue.map { "default: \($0)" } ?? "default: \(key.unsetMeaning)"
            Terminal.writeOutput(key.name.padding(toLength: width, withPad: " ", startingAt: 0) + value + "   (" + fallback + ")\n")
        }
        return .ok
    }
}

struct ConfigGet: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Print the value in effect (the default when none is set).")
    @Argument(help: "The setting, for example ollama.model.") var key: String

    func execute(environment: CLIEnvironment) async -> ExitCode {
        guard let found = ConfigKey.lookup(key) else { return .usage }
        if let value = found.stored ?? found.defaultValue {
            Terminal.writeOutput(TerminalApprover.visible(value) + "\n")
        } else {
            Terminal.writeError("\(found.name) is not set (\(found.unsetMeaning)).\n")
        }
        return .ok
    }
}

struct ConfigSet: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change a setting (asks for the parent PIN while kids mode is on).")
    @Argument(help: "The setting, for example ollama.model.") var key: String
    @Argument(help: "The new value.") var value: String

    func execute(environment: CLIEnvironment) async -> ExitCode {
        guard let found = ConfigKey.lookup(key) else { return .usage }
        guard let accepted = found.accept(value) else { return .usage }
        if let stop = Kids.guardChange(environment, purpose: "to change settings while kids mode is on") { return stop }
        Settings.set(accepted, forKey: found.name)
        Terminal.writeOutput("\(found.name) = \(TerminalApprover.visible(accepted))\n")
        return .ok
    }
}

struct ConfigUnset: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "unset", abstract: "Go back to a setting's default (asks for the parent PIN while kids mode is on).")
    @Argument(help: "The setting, for example ollama.model.") var key: String

    func execute(environment: CLIEnvironment) async -> ExitCode {
        guard let found = ConfigKey.lookup(key) else { return .usage }
        if let stop = Kids.guardChange(environment, purpose: "to change settings while kids mode is on") { return stop }
        Settings.set(nil, forKey: found.name)
        Terminal.writeOutput("\(found.name) is back to its default.\n")
        return .ok
    }
}

/// `tristan secret set|delete|status`: provider credentials in the Keychain (Credential Manager on Windows).
/// A value is only ever typed at a hidden prompt: never an argument, never printed, never logged.
struct SecretCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Store or remove a provider credential (Windows Credential Manager, or the Keychain on a Mac).",
        subcommands: [SecretSet.self, SecretDelete.self, SecretStatus.self])

    /// The credentials the providers on this computer read (`AzureConfig.keychainAccount`). The AWS access-key accounts
    /// exist only for the iPhone app: here Bedrock signs with the AWS CLI's own credentials (`aws configure` / SSO).
    static let names = [AzureConfig.keychainAccount]

    static func check(_ name: String) -> ExitCode? {
        names.contains(name) ? nil
            : Kids.refuse("'\(TerminalApprover.visible(name))' is not a credential tristan uses. Names: \(names.joined(separator: ", ")).")
    }
}

struct SecretSet: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Store a credential, typed at a hidden prompt (asks for the parent PIN while kids mode is on).")
    @Argument(help: "The credential, for example azure-openai-key.") var name: String

    func execute(environment: CLIEnvironment) async -> ExitCode {
        if let stop = SecretCommand.check(name) { return stop }
        guard environment.interactive else {
            return Kids.refuse("Storing a secret needs a terminal to type it in (never a pipe or an argument). Nothing was stored.")
        }
        if let stop = Kids.guardChange(environment, purpose: "to change credentials while kids mode is on") { return stop }
        guard let typed = environment.readSecret("Value for \(name) (hidden): ") else {
            return Kids.refuse("Nothing was entered. Nothing was stored.", .failed)
        }
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return Kids.refuse("The value is empty. Nothing was stored.") }
        guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return Kids.refuse("The value contains a control character. Nothing was stored.")
        }
        guard KeychainStore.set(value, account: name) else { return Kids.refuse("The credential could not be stored.", .failed) }
        Terminal.writeOutput("\(name) is stored.\n")
        return .ok
    }
}

struct SecretDelete: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "delete", abstract: "Remove a stored credential (asks for the parent PIN while kids mode is on).")
    @Argument(help: "The credential, for example azure-openai-key.") var name: String

    func execute(environment: CLIEnvironment) async -> ExitCode {
        if let stop = SecretCommand.check(name) { return stop }
        if let stop = Kids.guardChange(environment, purpose: "to change credentials while kids mode is on") { return stop }
        guard KeychainStore.get(name)?.isEmpty == false else {
            Terminal.writeOutput("\(name) is not set.\n")
            return .ok
        }
        guard KeychainStore.set("", account: name) else { return Kids.refuse("The credential could not be removed.", .failed) }
        Terminal.writeOutput("\(name) is removed.\n")
        return .ok
    }
}

struct SecretStatus: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show which credentials are stored (never their values).")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        let width = (SecretCommand.names.map(\.count).max() ?? 0) + 2
        for name in SecretCommand.names {
            let stored = KeychainStore.get(name)?.isEmpty == false
            Terminal.writeOutput(name.padding(toLength: width, withPad: " ", startingAt: 0) + (stored ? "set" : "not set") + "\n")
        }
        return .ok
    }
}
