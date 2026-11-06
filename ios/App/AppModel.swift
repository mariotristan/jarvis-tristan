import SwiftUI
import UIKit

/// The Mac this device is paired with. The secret itself lives in the Keychain, never in preferences.
struct PairedMac: Codable, Equatable {
    var name: String
    var host: String
    var port: UInt16
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairing: PairedMac?
    @Published var pairingError: String?
    @Published var showHistory = false
    @Published var showSettings = false

    let client = RemoteClient()
    let local: StandaloneEngine
    let mission: MissionModel
    private let defaults: UserDefaults
    private static let pairingKey = "pairedMac"
    static let secretAccount = "pairing-secret"

    #if DEBUG
    // Launch arguments that let the simulator be driven without tapping:
    //   -tristanPairURL <link>  -tristanAutoSubmit <task>  -tristanAutoApprove YES  -tristanStandaloneDemo YES
    private var autoSubmit: String?
    private var autoApprove = false
    private var autoSubmitted = false
    #endif

    init(defaults: UserDefaults = .standard, autoConnect: Bool = true) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = HistoryStore(url: support.appendingPathComponent("Tristan/standalone-history.json"))

        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let demo = value("-tristanStandaloneDemo") == "YES"
        let engine = demo
            ? StandaloneEngine(defaults: defaults, historyStore: nil) { _, mode in AzureOpenAIProvider(mode: mode, client: DemoChatClient()) }
            : StandaloneEngine(defaults: defaults, historyStore: store)
        #else
        let engine = StandaloneEngine(defaults: defaults, historyStore: store)
        #endif
        local = engine
        mission = MissionModel(remote: client, local: engine)
        client.deviceName = UIDevice.current.name
        if let data = defaults.data(forKey: Self.pairingKey), let saved = try? JSONDecoder().decode(PairedMac.self, from: data) {
            pairing = saved
        }
        #if DEBUG
        autoSubmit = value("-tristanAutoSubmit")
        autoApprove = value("-tristanAutoApprove") == "YES"
        if value("-tristanOpenSettings") == "YES" { showSettings = true }
        if demo { mission.mode = .standalone; return }
        if let link = value("-tristanPairURL") { mission.mode = .remote; handle(url: URL(string: link)!); return }
        #endif
        if autoConnect, pairing != nil, mission.mode == .remote { connect() }
    }

    func handle(url: URL) {
        guard let link = PairingLink.parse(url.absoluteString) else {
            pairingError = "That is not a valid Tristan pairing link."
            return
        }
        pair(link)
    }

    func pair(_ link: PairingLink) {
        guard KeychainStore.set(PairingSecret.hex(link.secret), account: Self.secretAccount) else {
            pairingError = "Could not save the pairing secret to the Keychain."
            return
        }
        let mac = PairedMac(name: link.name, host: link.host, port: link.port)
        defaults.set(try? JSONEncoder().encode(mac), forKey: Self.pairingKey)
        pairingError = nil
        pairing = mac
        mission.mode = .remote
        connect()
    }

    func connect() {
        guard let pairing, let hex = KeychainStore.get(Self.secretAccount), let secret = PairingSecret.data(fromHex: hex) else {
            unpair()
            return
        }
        client.deviceName = UIDevice.current.name
        client.connect(host: pairing.host, port: pairing.port, secret: secret)
    }

    func unpair() {
        client.disconnect()
        KeychainStore.set("", account: Self.secretAccount)
        defaults.removeObject(forKey: Self.pairingKey)
        pairing = nil
    }

    /// Switches between controlling a Mac and working on this device.
    func use(_ mode: MissionModel.Mode) {
        guard mission.mode != mode else { return }
        if mode == .standalone { client.disconnect() }
        mission.mode = mode
        if mode == .remote, pairing != nil { connect() }
    }

    #if DEBUG
    /// Called when state changes, to run the launch-argument automation.
    func automate() {
        if autoApprove, mission.approval != nil { mission.respond(.allow) }
        if let task = autoSubmit, !autoSubmitted, mission.state == .connected, mission.snapshot?.phase == .idle {
            autoSubmitted = true
            if mission.mode == .remote { mission.setProvider("DEMO") }
            mission.submit(task)
        }
    }
    #endif
}

/// What still needs setting up before standalone missions can run.
enum StandaloneSetup {
    static func hint(for provider: String) -> String? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-tristanStandaloneDemo") { return nil }   // the scripted demo needs no setup
        #endif
        let defaults = UserDefaults.standard
        func has(_ key: String) -> Bool { !(defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        switch provider {
        case "AZURE":
            let key = KeychainStore.get(AzureConfig.keychainAccount) ?? ""
            if !has("azure.endpoint") || !has("azure.deployment") || key.isEmpty { return "Azure OpenAI is not set up yet." }
        case "BEDROCK":
            let key = KeychainStore.get(KeychainAWSCredentials.accessKeyAccount) ?? ""
            let secret = KeychainStore.get(KeychainAWSCredentials.secretKeyAccount) ?? ""
            if key.isEmpty || secret.isEmpty { return "Bedrock is not set up yet." }
        default:
            break
        }
        return nil
    }
}

#if DEBUG
/// A scripted "model" for exercising the standalone screen in the simulator without any account. Debug builds only.
struct DemoChatClient: ChatCompletionsClient {
    func complete(_ body: [String: Any], onText: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        let messages = body["messages"] as? [[String: Any]] ?? []
        let sawToolResult = messages.contains { $0["role"] as? String == "tool" }
        func stream(_ text: String) async throws {
            for character in text { onText(String(character)); try await Task.sleep(for: .milliseconds(15)) }
        }
        if !sawToolResult {
            let intro = "I'll add the login function in a new file."
            try await stream(intro)
            let arguments = #"{"path":"api/login.ts","content":"export function login(user: User): string {\n  return sign({ sub: user.id });\n}\n"}"#
            return ["choices": [["message": ["role": "assistant", "content": intro,
                                             "tool_calls": [["id": "call_demo", "type": "function",
                                                             "function": ["name": "write_file", "arguments": arguments]]]],
                                 "finish_reason": "tool_calls"]]]
        }
        let done = "Done. I created api/login.ts with a login function."
        try await stream(done)
        return ["choices": [["message": ["role": "assistant", "content": done], "finish_reason": "stop"]]]
    }
}
#endif
