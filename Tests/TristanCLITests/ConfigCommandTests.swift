import XCTest
import TristanCore
@testable import TristanCLICore

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func add(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

/// Scripted answers for the no-echo prompts (PIN and secret), with the prompts that were shown.
private final class Prompts: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String?]
    private var shown: [String] = []
    init(_ answers: [String?] = []) { self.answers = answers }
    func next(_ prompt: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        shown.append(prompt)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
    var asked: [String] { lock.lock(); defer { lock.unlock() }; return shown }
}

private struct Unused: AgentProvider {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { $0.finish() }
    }
}

final class ConfigCommandTests: XCTestCase {
    private var saved: SettingsBackend!
    private var savedPINMemory = false
    private var savedNoKeychain = false
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)")
    private let secretNames = ["azure-openai-key"]

    override func setUp() {
        saved = Settings.backend
        Settings.backend = MemoryBackend()
        savedPINMemory = ParentPIN.inMemory
        ParentPIN.inMemory = true
        ParentPIN.clearInMemory()
        savedNoKeychain = NoKeychain.enabled
        NoKeychain.enabled = true   // KeychainStore keeps values in memory: no real Keychain or Credential Manager
        for name in secretNames { KeychainStore.set("", account: name) }
    }

    override func tearDown() {
        for name in secretNames { KeychainStore.set("", account: name) }
        NoKeychain.enabled = savedNoKeychain
        ParentPIN.clearInMemory()
        ParentPIN.inMemory = savedPINMemory
        Settings.backend = saved
    }

    /// Runs the command as the command line would; returns the exit code and everything written to stdout and stderr.
    private func exec(_ arguments: [String], interactive: Bool = true, pins: Prompts = Prompts(),
                      secrets: Prompts = Prompts()) async throws -> (ExitCode, String) {
        let out = Sink()
        Terminal.capture = { out.add($0) }
        Terminal.captureError = { out.add($0) }
        defer { Terminal.capture = nil; Terminal.captureError = nil }
        let parsed: CLI.Parsed = CLI.parse(arguments)
        switch parsed {
        case .stop(let code, let message):
            return (code, message)
        case .run(let command):
            var env = CLIEnvironment(interactive: interactive, readPIN: { pins.next($0) },
                                     makeProvider: { _, _ in Unused() }, installInterrupt: false,
                                     historyURL: scratch.appendingPathComponent("history.json"),
                                     sessions: SessionRegistry(directory: scratch.appendingPathComponent("sessions"), isAlive: { _ in true }))
            env.readSecret = { secrets.next($0) }
            let code = await command.execute(environment: env)
            return (code, out.value)
        }
    }

    // MARK: - config

    func testUnknownKeyIsRefused() async throws {
        for arguments in [["config", "set", "nope.key", "x"], ["config", "get", "nope.key"], ["config", "unset", "nope.key"]] {
            let (code, _) = try await exec(arguments)
            XCTAssertEqual(code, .usage, arguments.joined(separator: " "))
        }
        XCTAssertNil(Settings.backend.object(forKey: "nope.key"))
    }

    func testKidsModeAndAllowRulesAreRefused() async throws {
        for key in ["kidsMode", "allowRules"] {
            let (set, _) = try await exec(["config", "set", key, "false"])
            XCTAssertEqual(set, .usage, key)
            let (unset, _) = try await exec(["config", "unset", key])
            XCTAssertEqual(unset, .usage, key)
            let (get, _) = try await exec(["config", "get", key])
            XCTAssertEqual(get, .usage, key)
        }
        Settings.set(true, forKey: "kidsMode")
        let (code, _) = try await exec(["config", "unset", "kidsMode"])
        XCTAssertEqual(code, .usage)
        XCTAssertTrue(Settings.bool("kidsMode"))
    }

    func testInvalidOllamaHostIsRefused() async throws {
        for host in ["http://example.com:11434", "https://localhost:11434", "http://user@localhost:11434", "ftp://127.0.0.1",
                     "not a url", "http://192.168.1.2:11434"] {
            let (code, _) = try await exec(["config", "set", "ollama.host", host])
            XCTAssertEqual(code, .usage, host)
        }
        XCTAssertNil(Settings.string("ollama.host"))
        let (ok, _) = try await exec(["config", "set", "ollama.host", "http://127.0.0.1:5005"])
        XCTAssertEqual(ok, .ok)
        XCTAssertEqual(Settings.string("ollama.host"), "http://127.0.0.1:5005")
    }

    func testValuesUseTheProviderValidators() async throws {
        let bad: [(String, String)] = [("bedrock.region", "us-east-1\n"), ("bedrock.region", "US-EAST-1"), ("bedrock.region", "mars"),
                                       ("azure.deployment", "a/b"), ("azure.deployment", "gpt\n"),
                                       ("azure.endpoint", "https://evil.example.com"), ("azure.endpoint", "http://x.openai.azure.com"),
                                       ("ollama.model", "llama\u{1B}[2J"), ("copilot.model", "gpt 5"), ("copilot.model", "-x"), ("bedrock.profile", "a\tb"),
                                       ("bedrock.model", "a b"), ("azure.apiVersion", "2024-10-21&x=1")]
        for (key, value) in bad {
            let (code, _) = try await exec(["config", "set", key, value])
            XCTAssertEqual(code, .usage, "\(key)=\(value.debugDescription)")
            XCTAssertNil(Settings.string(key), key)
        }
        let good: [(String, String)] = [("bedrock.region", "eu-west-2"), ("azure.deployment", "gpt-4o.mini_1"),
                                        ("azure.endpoint", "https://my-resource.openai.azure.com"), ("ollama.model", "llama3.1:8b"),
                                        ("copilot.model", "gpt-5"), ("bedrock.profile", "work"),
                                        ("bedrock.model", "us.anthropic.claude-sonnet-4-20250514-v1:0"), ("azure.apiVersion", "2025-01-01-preview")]
        for (key, value) in good {
            let (code, out) = try await exec(["config", "set", key, value])
            XCTAssertEqual(code, .ok, "\(key)=\(value): \(out)")
            XCTAssertEqual(Settings.string(key), value, key)
        }
    }

    func testRoundTripSetGetListUnset() async throws {
        let (listBefore, before) = try await exec(["config", "list"])
        XCTAssertEqual(listBefore, .ok)
        for key in ["ollama.host", "ollama.model", "azure.endpoint", "azure.deployment", "azure.apiVersion",
                    "bedrock.region", "bedrock.model", "bedrock.profile", "copilot.model"] {
            XCTAssertTrue(before.contains(key), "list shows \(key)")
        }
        XCTAssertTrue(before.contains("http://localhost:11434"), "list shows defaults")
        XCTAssertFalse(before.contains("kidsMode"))

        let (set, _) = try await exec(["config", "set", "ollama.model", "  mock  "])
        XCTAssertEqual(set, .ok)
        XCTAssertEqual(Settings.string("ollama.model"), "mock", "surrounding spaces trimmed")
        let (get, value) = try await exec(["config", "get", "ollama.model"])
        XCTAssertEqual(get, .ok)
        XCTAssertEqual(value, "mock\n")
        let (_, after) = try await exec(["config", "list"])
        XCTAssertTrue(after.contains("mock"))

        let (unset, _) = try await exec(["config", "unset", "ollama.model"])
        XCTAssertEqual(unset, .ok)
        XCTAssertNil(Settings.backend.object(forKey: "ollama.model"))
        let (_, defaultHost) = try await exec(["config", "get", "ollama.host"])
        XCTAssertEqual(defaultHost, "http://localhost:11434\n", "get prints the default when nothing is set")
    }

    func testListSanitisesStoredValues() async throws {
        Settings.set("evil\u{1B}]52;c;aGk=\u{07}", forKey: "copilot.model")   // written by hand into the settings file
        let (_, out) = try await exec(["config", "list"])
        XCTAssertFalse(out.contains("\u{1B}"))
        XCTAssertTrue(out.contains("\\e"))
        let (_, got) = try await exec(["config", "get", "copilot.model"])
        XCTAssertFalse(got.contains("\u{1B}"))
    }

    // MARK: - secret

    func testSecretSetWithoutTerminalIsRefused() async throws {
        let secrets = Prompts(["should-not-be-read"])
        let (code, out) = try await exec(["secret", "set", "azure-openai-key"], interactive: false, secrets: secrets)
        XCTAssertEqual(code, .usage)
        XCTAssertEqual(secrets.asked, [], "nothing is read without a terminal")
        XCTAssertNil(KeychainStore.get("azure-openai-key"))
        XCTAssertFalse(out.contains("should-not-be-read"))
    }

    func testSecretSetStoresWithoutEchoing() async throws {
        let value = "sk-very-secret-0123456789"
        let (code, out) = try await exec(["secret", "set", "azure-openai-key"], secrets: Prompts(["  \(value)  "]))
        XCTAssertEqual(code, .ok, out)
        XCTAssertEqual(KeychainStore.get("azure-openai-key"), value, "surrounding whitespace trimmed")
        XCTAssertFalse(out.contains(value), "the value never appears in output")
        XCTAssertFalse(out.contains("0123456789"))
        let (_, status) = try await exec(["secret", "status"])
        XCTAssertFalse(status.contains(value))
    }

    func testSecretSetRejectsEmptyControlAndUnknown() async throws {
        for answer in ["", "   ", nil, "abc\u{1B}def", "abc\u{7}", "abc\u{202E}def", "key\u{200B}"] as [String?] {
            let (code, _) = try await exec(["secret", "set", "azure-openai-key"], secrets: Prompts([answer]))
            XCTAssertNotEqual(code, .ok, String(describing: answer))
            XCTAssertNil(KeychainStore.get("azure-openai-key"), String(describing: answer))
        }
        for name in ["kids.pin", "aws-whatever", "azure-openai-key2"] {
            let secrets = Prompts(["x"])
            let (code, _) = try await exec(["secret", "set", name], secrets: secrets)
            XCTAssertEqual(code, .usage, name)
            XCTAssertEqual(secrets.asked, [], name)
            let (delete, _) = try await exec(["secret", "delete", name])
            XCTAssertEqual(delete, .usage, name)
        }
    }

    func testSecretStatusShowsOnlySetOrNotSet() async throws {
        let (_, empty) = try await exec(["secret", "status"])
        XCTAssertTrue(empty.contains("azure-openai-key"))
        XCTAssertTrue(empty.contains("not set"))
        KeychainStore.set("hunter2-key", account: "azure-openai-key")
        let (code, status) = try await exec(["secret", "status"])
        XCTAssertEqual(code, .ok)
        XCTAssertFalse(status.contains("hunter2"))
        XCTAssertFalse(status.contains("not set"))
        XCTAssertTrue(status.contains("set"))

        let (delete, _) = try await exec(["secret", "delete", "azure-openai-key"])
        XCTAssertEqual(delete, .ok)
        XCTAssertNil(KeychainStore.get("azure-openai-key"))
    }

    // MARK: - kids mode

    func testKidsModeNeedsThePINForEveryWrite() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        Settings.set("old", forKey: "ollama.model")
        KeychainStore.set("old-key", account: "azure-openai-key")

        // Wrong PIN: nothing changes, and the secret is never asked for.
        let writes: [[String]] = [["config", "set", "ollama.model", "new"], ["config", "unset", "ollama.model"],
                                  ["secret", "set", "azure-openai-key"], ["secret", "delete", "azure-openai-key"]]
        for arguments in writes {
            let secrets = Prompts(["new-key"])
            let (code, _) = try await exec(arguments, pins: Prompts(["9999"]), secrets: secrets)
            XCTAssertEqual(code, .failed, arguments.joined(separator: " "))
            XCTAssertEqual(secrets.asked, [], arguments.joined(separator: " "))
            XCTAssertEqual(Settings.string("ollama.model"), "old")
            XCTAssertEqual(KeychainStore.get("azure-openai-key"), "old-key")
        }
        // No terminal: refused, nothing changes.
        for arguments in writes {
            let (code, _) = try await exec(arguments, interactive: false, pins: Prompts(["1234"]), secrets: Prompts(["new-key"]))
            XCTAssertEqual(code, .usage, arguments.joined(separator: " "))
            XCTAssertEqual(Settings.string("ollama.model"), "old")
            XCTAssertEqual(KeychainStore.get("azure-openai-key"), "old-key")
        }
        // Right PIN: each write goes through.
        let (set, _) = try await exec(writes[0], pins: Prompts(["1234"]))
        XCTAssertEqual(set, .ok)
        XCTAssertEqual(Settings.string("ollama.model"), "new")
        let (unset, _) = try await exec(writes[1], pins: Prompts(["1234"]))
        XCTAssertEqual(unset, .ok)
        XCTAssertNil(Settings.string("ollama.model"))
        let (secret, _) = try await exec(writes[2], pins: Prompts(["1234"]), secrets: Prompts(["new-key"]))
        XCTAssertEqual(secret, .ok)
        XCTAssertEqual(KeychainStore.get("azure-openai-key"), "new-key")
        let (delete, _) = try await exec(writes[3], pins: Prompts(["1234"]))
        XCTAssertEqual(delete, .ok)
        XCTAssertNil(KeychainStore.get("azure-openai-key"))
        XCTAssertTrue(Settings.bool("kidsMode"), "kids mode itself is untouched")
    }

    func testKidsModeWithoutPINRefusesWrites() async throws {
        Settings.set(true, forKey: "kidsMode")
        for arguments in [["config", "set", "ollama.model", "new"], ["config", "unset", "ollama.model"],
                          ["secret", "set", "azure-openai-key"], ["secret", "delete", "azure-openai-key"]] {
            let (code, out) = try await exec(arguments, pins: Prompts(["1234"]), secrets: Prompts(["k"]))
            XCTAssertEqual(code, .usage, arguments.joined(separator: " "))
            XCTAssertTrue(out.contains("Ask a parent to change it in the Tristan app"), out)
        }
        XCTAssertNil(Settings.string("ollama.model"))
        XCTAssertNil(KeychainStore.get("azure-openai-key"))
    }

    func testKidsModeReadsNeedNoPIN() async throws {
        XCTAssertTrue(ParentPIN.set("1234"))
        Settings.set(true, forKey: "kidsMode")
        let pins = Prompts()
        for arguments in [["config", "list"], ["config", "get", "ollama.host"], ["secret", "status"]] {
            let (code, _) = try await exec(arguments, pins: pins)
            XCTAssertEqual(code, .ok, arguments.joined(separator: " "))
        }
        XCTAssertEqual(pins.asked, [])
    }

    // MARK: - providers

    func testProvidersNameTheFixingCommand() async {
        Settings.set("http://127.0.0.1:9", forKey: "ollama.host")   // nothing listens on the discard port
        let ollama = await ProvidersCommand.problem(.ollama)
        XCTAssertTrue(ollama?.contains("tristan config set ollama.host") ?? false, ollama ?? "nil")
        let azure = await ProvidersCommand.problem(.azure, locate: { _ in nil })
        XCTAssertTrue(azure?.contains("tristan config set azure.endpoint") ?? false, azure ?? "nil")
        Settings.set("https://r.openai.azure.com", forKey: "azure.endpoint")
        Settings.set("gpt", forKey: "azure.deployment")
        let key = await ProvidersCommand.problem(.azure, locate: { _ in nil })
        XCTAssertTrue(key?.contains("tristan secret set azure-openai-key") ?? false, key ?? "nil")
        Settings.set("mars", forKey: "bedrock.region")
        let bedrock = await ProvidersCommand.problem(.bedrock, locate: { _ in "aws" })
        XCTAssertTrue(bedrock?.contains("tristan config set bedrock.region") ?? false, bedrock ?? "nil")
    }
}
