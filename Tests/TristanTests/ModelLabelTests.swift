import XCTest
import TristanCore
@testable import Tristan

final class ModelLabelTests: XCTestCase {
    private func label(_ kind: ProviderKind, _ settings: [String: String] = [:]) -> String {
        kind.modelLabel(setting: { settings[$0] })
    }

    func testChosenModelsAreShown() {
        XCTAssertEqual(label(.azure, ["azure.deployment": " gpt-4o "]), "gpt-4o")
        XCTAssertEqual(label(.ollama, ["ollama.model": "qwen3:8b"]), "qwen3:8b")
        XCTAssertEqual(label(.bedrock, ["bedrock.model": "my.model"]), "my.model")
        XCTAssertEqual(label(.copilot, ["copilot.model": "gpt-5"]), "gpt-5")
    }

    func testDefaultsWhenNothingIsChosen() {
        XCTAssertEqual(label(.claude), "default")
        XCTAssertEqual(label(.copilot), "default")
        XCTAssertEqual(label(.bedrock), BedrockConfig.defaultModel)
        XCTAssertEqual(label(.azure), "not set")
        XCTAssertEqual(label(.ollama, ["ollama.model": "  "]), "auto")
        XCTAssertEqual(label(.demo), "scripted")
    }

    func testClaudeShowsPinnedThenRememberedThenDefault() {
        XCTAssertEqual(ProviderKind.claude.modelLabel(setting: { _ in nil }, remembered: "claude-last", pinned: "opus"), "opus")
        XCTAssertEqual(ProviderKind.claude.modelLabel(setting: { _ in nil }, remembered: "claude-last"), "claude-last")
        XCTAssertEqual(ProviderKind.claude.modelLabel(setting: { _ in nil }), "default")
    }

    func testOllamaShowsTheInstalledModelItWillUse() {
        let installed = ["llama3.1:8b", "qwen3:8b"]
        XCTAssertEqual(ProviderKind.ollama.modelLabel(setting: { _ in nil }, installed: installed), "llama3.1:8b")
        XCTAssertEqual(ProviderKind.ollama.modelLabel(setting: { $0 == "ollama.model" ? "qwen3:8b" : nil }, installed: installed), "qwen3:8b")
        XCTAssertEqual(ProviderKind.ollama.modelLabel(setting: { _ in nil }, installed: []), "none installed")
    }

    func testClaudePinnedModelComesFromTheEnvironmentOrSettingsFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("claude-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(ProviderKind.claudePinnedModel(environment: [:], settingsFile: file))
        try Data("{\"model\": \"sonnet\"}".utf8).write(to: file)
        XCTAssertEqual(ProviderKind.claudePinnedModel(environment: [:], settingsFile: file), "sonnet")
        XCTAssertEqual(ProviderKind.claudePinnedModel(environment: ["ANTHROPIC_MODEL": "env-model"], settingsFile: file), "env-model")
    }
}

private final class ProbeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class ClaudeModelProbeTests: XCTestCase {
    private var retained: [Session] = []

    private func hub(probe: @escaping () async -> String?) -> Session {
        UserDefaults.standard.removeObject(forKey: "reportedModels")
        let hub = Session(history: nil, music: SpotifyController(runner: FakeSpotify(), isRunning: { true }, releaseDelay: .zero))
        retained.append(hub)
        hub.soundsOn = false; hub.voiceOn = false; hub.notificationsOn = false
        hub.kidsMode = false
        hub.active.provider = .claude
        hub.probeClaudeModel = probe
        return hub
    }

    override func tearDown() async throws {
        retained.removeAll()
        for key in ["kidsMode", "reportedModels"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testTheModelIsLearnedOnceAndThenRemembered() async {
        let calls = ProbeCalls()
        let hub = hub { calls.bump(); return "claude-probed" }
        await hub.refreshModelLabel()
        await hub.refreshModelLabel()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(hub.reportedModels["CLAUDE"], "claude-probed")
        if ProviderKind.claudePinnedModel() == nil { XCTAssertEqual(hub.modelLabel, "claude-probed") }
    }

    func testNoProbeInKidsModeOrForOtherProviders() async {
        let calls = ProbeCalls()
        let hub = hub { calls.bump(); return "x" }
        hub.kidsMode = true
        await hub.refreshModelLabel()
        hub.kidsMode = false
        hub.active.provider = .azure
        await hub.refreshModelLabel()
        XCTAssertEqual(calls.count, 0)
    }
}
