import XCTest
@testable import Tristan

/// A pretend Azure OpenAI that plays back canned responses and records every request.
final class ScriptedModel: ChatCompletionsClient, @unchecked Sendable {
    private var responses: [[String: Any]]
    private(set) var bodies: [[String: Any]] = []
    init(_ responses: [[String: Any]]) { self.responses = responses }

    func complete(_ body: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        bodies.append(body)
        guard !responses.isEmpty else { throw AzureError(message: "script exhausted") }
        return responses.removeFirst()
    }

    static func call(_ name: String, _ arguments: String, id: String = "c1") -> [String: Any] {
        ["choices": [["message": ["role": "assistant", "content": NSNull(),
                                  "tool_calls": [["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]]],
                      "finish_reason": "tool_calls"]]]
    }

    static func say(_ text: String) -> [String: Any] {
        ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]]]
    }
}

@MainActor
final class StandaloneTests: XCTestCase {
    private var base: URL!
    private var workspace: URL!
    private var defaults: UserDefaults!
    private var historyURL: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-standalone-\(UUID().uuidString.prefix(8))")
        workspace = base.appendingPathComponent("Workspace")
        historyURL = base.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suite = "tristan-standalone-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for account in [KeychainAWSCredentials.accessKeyAccount, KeychainAWSCredentials.secretKeyAccount, KeychainAWSCredentials.sessionTokenAccount] {
            KeychainStore.set("", account: account)
        }
    }

    private func engine(_ model: ScriptedModel) -> StandaloneEngine {
        StandaloneEngine(defaults: defaults, historyStore: HistoryStore(url: historyURL), workspace: workspace) { _, mode in
            AzureOpenAIProvider(mode: mode, client: model)
        }
    }

    private func eventually(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    private var written: URL { workspace.appendingPathComponent("hello.txt") }
    private let writeHello = #"{"path":"hello.txt","content":"hi"}"#

    // MARK: missions

    func testApprovedWriteCreatesTheFileAndIsRecorded() async throws {
        let model = ScriptedModel([ScriptedModel.call("write_file", writeHello), ScriptedModel.say("Created hello.txt.")])
        let engine = engine(model)
        engine.submit("make a hello file")
        try await eventually { engine.approval != nil }
        XCTAssertEqual(engine.approval?.summary, "Allow Write?")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path), "nothing is written before approval")
        engine.respond(.allow)
        try await eventually { engine.phase == .done }
        XCTAssertEqual(engine.phase, .done)
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "hi")
        XCTAssertTrue(engine.code.contains("hello.txt"))
        XCTAssertEqual(engine.history.first?.task, "make a hello file")
        XCTAssertEqual(HistoryStore(url: historyURL).load().count, 1, "history is saved to disk")
    }

    func testDeniedWriteLeavesNoFile() async throws {
        let model = ScriptedModel([ScriptedModel.call("write_file", writeHello), ScriptedModel.say("I could not write it.")])
        let engine = engine(model)
        engine.submit("make a hello file")
        try await eventually { engine.approval != nil }
        engine.respond(.deny)
        try await eventually { engine.phase == .done }
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path))
        XCTAssertTrue(String(describing: model.bodies.last?["messages"] ?? "").contains("denied"), "the model is told")
    }

    func testAutoModeWritesInsideTheFolderWithoutAsking() async throws {
        let model = ScriptedModel([ScriptedModel.call("write_file", writeHello), ScriptedModel.say("Done.")])
        let engine = engine(model)
        engine.mode = .auto
        engine.submit("make a hello file")
        try await eventually { engine.phase == .done }
        XCTAssertNil(engine.approval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
    }

    func testAlwaysAllowIsRememberedForTheNextMission() async throws {
        let first = ScriptedModel([ScriptedModel.call("write_file", writeHello), ScriptedModel.say("ok")])
        let engine = engine(first)
        engine.submit("one")
        try await eventually { engine.approval != nil }
        XCTAssertEqual(engine.approval?.canAlwaysAllow, true)
        engine.respond(.always)
        try await eventually { engine.phase == .done }
        XCTAssertEqual(engine.allowRules.count, 1)
        XCTAssertEqual(StandaloneEngine(defaults: defaults, historyStore: nil, workspace: workspace).allowRules.count, 1, "rules survive a restart")
    }

    func testThereIsNoShellOnThisDevice() async throws {
        XCTAssertEqual(AgentToolSpec.definitions.map(\.name), ["read_file", "list_dir", "write_file"])
        let model = ScriptedModel([ScriptedModel.call("run_command", #"{"command":"touch pwned.txt"}"#), ScriptedModel.say("I cannot run commands.")])
        let engine = engine(model)
        engine.mode = .auto
        engine.submit("run something")
        try await eventually { engine.phase == .done }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("pwned.txt").path))
        XCTAssertTrue(String(describing: model.bodies.last?["messages"] ?? "").contains("cannot be run"))
        let offered = (model.bodies.first?["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(offered, ["read_file", "list_dir", "write_file"], "the model is never offered a shell")
    }

    func testWritesOutsideTheFolderAreRefused() async throws {
        let model = ScriptedModel([ScriptedModel.call("write_file", #"{"path":"../escape.txt","content":"x"}"#), ScriptedModel.say("ok")])
        let engine = engine(model)
        engine.mode = .auto
        engine.submit("escape")
        try await eventually { engine.phase == .done }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape.txt").path))
        XCTAssertTrue(String(describing: model.bodies.last?["messages"] ?? "").contains("outside the working folder"))
    }

    func testAnUnconfiguredProviderFailsWithAReadableMessage() async throws {
        let engine = StandaloneEngine(defaults: defaults, historyStore: nil, workspace: workspace) { _, mode in
            AzureOpenAIProvider(mode: mode, client: AzureHTTPClient(config: AzureConfig(endpoint: "", deployment: "", apiVersion: AzureConfig.defaultAPIVersion)))
        }
        engine.submit("anything")
        try await eventually { engine.phase == .failed }
        XCTAssertEqual(engine.phase, .failed)
        XCTAssertTrue(engine.log.contains { $0.text.contains("endpoint") })
    }

    func testAbortStopsAMissionWaitingForApproval() async throws {
        let engine = engine(ScriptedModel([ScriptedModel.call("write_file", writeHello), ScriptedModel.say("ok")]))
        engine.submit("x")
        try await eventually { engine.approval != nil }
        engine.cancel()
        try await eventually { engine.phase == .failed }
        XCTAssertEqual(engine.status, "ABORTED")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(engine.history.first?.status, "aborted")
    }

    func testOnlyOneMissionAtATime() async throws {
        let engine = engine(ScriptedModel([ScriptedModel.call("write_file", writeHello), ScriptedModel.say("ok")]))
        engine.submit("first")
        try await eventually { engine.approval != nil }
        engine.submit("second")
        XCTAssertEqual(engine.notice, "A mission is already running.")
        engine.respond(.allow)
        try await eventually { engine.phase == .done }
    }

    // MARK: folders and settings

    func testFolderChoiceIsLimitedToKnownFoldersAndPersists() throws {
        let engine = engine(ScriptedModel([]))
        XCTAssertEqual(engine.folders.map(\.name), ["Workspace"])
        engine.setFolder(path: "/etc")
        XCTAssertEqual(engine.snapshot.folder, workspace.path)
        XCTAssertNotNil(engine.notice)

        let picked = base.appendingPathComponent("Picked")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        engine.addFolder(picked)
        XCTAssertEqual(engine.folders.map(\.name), ["Workspace", "Picked"])
        XCTAssertEqual(URL(fileURLWithPath: engine.snapshot.folder).lastPathComponent, "Picked")

        let again = StandaloneEngine(defaults: defaults, historyStore: nil, workspace: workspace)
        XCTAssertEqual(again.folders.map(\.name), ["Workspace", "Picked"], "bookmarks survive a restart")
        XCTAssertEqual(URL(fileURLWithPath: again.snapshot.folder).lastPathComponent, "Picked")
    }

    func testProviderAndModePersistButYoloIsNotAnOption() {
        let engine = engine(ScriptedModel([]))
        engine.provider = "BEDROCK"
        engine.mode = .auto
        let again = StandaloneEngine(defaults: defaults, historyStore: nil, workspace: workspace)
        XCTAssertEqual(again.provider, "BEDROCK")
        XCTAssertEqual(again.mode, .auto)
        defaults.set("YOLO", forKey: "standalone.mode")
        XCTAssertEqual(StandaloneEngine(defaults: defaults, historyStore: nil, workspace: workspace).mode, .ask, "a stored YOLO is ignored")
    }

    func testAWSKeysComeFromTheKeychainAndAreRequired() async throws {
        for account in [KeychainAWSCredentials.accessKeyAccount, KeychainAWSCredentials.secretKeyAccount, KeychainAWSCredentials.sessionTokenAccount] {
            KeychainStore.set("", account: account)
        }
        do { _ = try await KeychainAWSCredentials().credentials(); XCTFail("expected an error without keys") } catch {
            XCTAssertTrue("\(error)".contains("access key") || (error as? BedrockError)?.message.contains("access key") == true)
        }
        KeychainStore.set("AKIAEXAMPLE", account: KeychainAWSCredentials.accessKeyAccount)
        KeychainStore.set("secret", account: KeychainAWSCredentials.secretKeyAccount)
        var credentials = try await KeychainAWSCredentials().credentials()
        XCTAssertEqual(credentials.accessKey, "AKIAEXAMPLE")
        XCTAssertNil(credentials.sessionToken)
        KeychainStore.set("TOKEN", account: KeychainAWSCredentials.sessionTokenAccount)
        credentials = try await KeychainAWSCredentials().credentials()
        XCTAssertEqual(credentials.sessionToken, "TOKEN")
    }

    // MARK: the unified model

    func testMissionModelReadsFromTheActiveSource() {
        let remote = RemoteClient()
        let local = engine(ScriptedModel([]))
        let mission = MissionModel(remote: remote, local: local, mode: .standalone)
        XCTAssertEqual(mission.snapshot?.macName, "This device")
        XCTAssertEqual(mission.state, .connected)
        mission.setMode("YOLO")
        XCTAssertEqual(local.mode, .ask, "YOLO cannot be chosen on the device")
        mission.setMode("AUTO")
        XCTAssertEqual(local.mode, .auto)
        mission.setProvider("BEDROCK")
        XCTAssertEqual(local.provider, "BEDROCK")
        mission.mode = .remote
        XCTAssertNil(mission.snapshot, "in remote mode it shows the Mac, which is not connected")
        XCTAssertEqual(mission.state, .disconnected)
        UserDefaults.standard.removeObject(forKey: "appMode")
    }
}
