import Foundation

/// Runs missions on this device: the shared agent loop talking straight to Azure OpenAI or Bedrock, with file tools
/// confined to one folder (the app's own Workspace, or a folder picked in the Files app) and no shell.
@MainActor
final class StandaloneEngine: ObservableObject {
    struct FolderBookmark: Codable, Equatable {
        var name: String
        var data: Data
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "STANDING BY"
    @Published private(set) var log: [RemoteLogLine] = []
    @Published private(set) var code = ""
    @Published private(set) var approval: RemoteApproval?
    @Published private(set) var history: [MissionRecord] = []
    @Published private(set) var notice: String?
    @Published private(set) var missionID = UUID().uuidString
    @Published private(set) var folders: [RemoteFolder] = []
    @Published var provider = "AZURE" { didSet { defaults.set(provider, forKey: Keys.provider) } }
    @Published var mode: ApprovalMode = .ask { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    @Published private(set) var folderPath: String { didSet { defaults.set(folderPath, forKey: Keys.folder) } }
    @Published private(set) var allowRules: [ApprovalRule] = [] {
        didSet { defaults.set(try? JSONEncoder().encode(allowRules), forKey: Keys.rules) }
    }

    let providers = ["AZURE", "BEDROCK"]
    typealias ProviderFactory = (String, ApprovalMode) -> AgentProvider?

    private enum Keys {
        static let provider = "standalone.provider", mode = "standalone.mode", folder = "standalone.folder"
        static let bookmarks = "standalone.bookmarks", rules = "standalone.rules", memory = "standalone.memory"
    }

    private let defaults: UserDefaults
    private let historyStore: HistoryStore?
    private let makeProvider: ProviderFactory
    private let workspace: URL
    private var bookmarks: [FolderBookmark] = []
    private var extraURLs: [String: URL] = [:]
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var pendingRule: ApprovalRule?
    private var runner: Task<Void, Never>?
    private var currentTask = ""
    private var recorded = false
    private var remembered = false
    @Published private(set) var memory = ConversationMemory()

    var busy: Bool { phase == .working || phase == .awaitingApproval }

    /// `workspace` is the folder offered by default: the app's Documents/Workspace, which also shows up in the Files app.
    init(defaults: UserDefaults = .standard, historyStore: HistoryStore? = nil, workspace: URL? = nil,
         providerFactory: ProviderFactory? = nil) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.makeProvider = providerFactory ?? StandaloneEngine.standardProvider
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.workspace = workspace ?? documents.appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.workspace, withIntermediateDirectories: true)
        self.folderPath = defaults.string(forKey: Keys.folder) ?? self.workspace.path

        if let saved = defaults.string(forKey: Keys.provider), providers.contains(saved) { provider = saved }
        if let saved = defaults.string(forKey: Keys.mode), let value = ApprovalMode(rawValue: saved), value != .yolo { mode = value }
        if let data = defaults.data(forKey: Keys.bookmarks), let saved = try? JSONDecoder().decode([FolderBookmark].self, from: data) {
            bookmarks = saved
        }
        if let data = defaults.data(forKey: Keys.rules), let saved = try? JSONDecoder().decode([ApprovalRule].self, from: data) {
            allowRules = saved
        }
        if let data = defaults.data(forKey: Keys.memory), let saved = try? JSONDecoder().decode(ConversationMemory.self, from: data) {
            memory = saved
        }
        history = historyStore?.load() ?? []
        refreshFolders()
        if !folders.contains(where: { $0.path == folderPath }) { folderPath = self.workspace.path }
    }

    static func standardProvider(_ name: String, mode: ApprovalMode) -> AgentProvider? {
        switch name {
        case "AZURE":
            return AzureOpenAIProvider(mode: mode)
        case "BEDROCK":
            let config = BedrockConfig.load()
            return BedrockProvider(mode: mode, client: BedrockStreamingClient(config: config, credentialProvider: KeychainAWSCredentials()))
        default:
            return nil
        }
    }

    // MARK: what the screen shows

    var snapshot: RemoteSnapshot {
        RemoteSnapshot(macName: "This device", missionID: missionID, phase: phase, status: status, provider: provider, providers: providers,
                       mode: mode.rawValue, folder: folderPath, folders: folders, musicOn: false, nowPlaying: nil)
    }

    // MARK: folders

    private func refreshFolders() {
        var list = [RemoteFolder(path: workspace.path, name: "Workspace")]
        extraURLs = [:]
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark.data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                  !list.contains(where: { $0.path == url.path }) else { continue }
            extraURLs[url.path] = url
            list.append(RemoteFolder(path: url.path, name: bookmark.name))
        }
        folders = list
    }

    /// A folder chosen in the Files app. Access is kept as a bookmark, so it survives restarts.
    func addFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            notice = "Could not keep access to that folder."
            return
        }
        bookmarks.removeAll { $0.name == url.lastPathComponent && $0.data == data }
        bookmarks.append(FolderBookmark(name: url.lastPathComponent, data: data))
        defaults.set(try? JSONEncoder().encode(bookmarks), forKey: Keys.bookmarks)
        refreshFolders()
        folderPath = url.path
    }

    /// Only folders the engine already knows about can be chosen.
    func setFolder(path: String) {
        guard !busy else { notice = "Wait for the current mission to finish."; return }
        guard folders.contains(where: { $0.path == path }) else { notice = "That folder is not available."; return }
        folderPath = path
    }

    // MARK: missions

    func submit(_ task: String) {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !busy else { notice = "A mission is already running."; return }
        guard let impl = makeProvider(provider, mode) else { notice = "\(provider) is not available."; return }

        missionID = UUID().uuidString
        log = []
        code = ""
        approval = nil
        notice = nil
        currentTask = text
        recorded = false
        remembered = false
        phase = .working
        status = "INITIALIZING"
        add("Task: \(text)", "info")

        let directory = URL(fileURLWithPath: folderPath)
        let briefed = memory.compose(task: text, folder: folderPath)
        if briefed != text { add("Remembering earlier missions from this conversation", "info") }
        let scopedURL = extraURLs[folderPath]
        let scoped = scopedURL?.startAccessingSecurityScopedResource() ?? false
        runner = Task { [weak self] in
            let stream = impl.run(task: briefed, workingDirectory: directory) { [weak self] request in
                await self?.ask(request) ?? false
            }
            for await event in stream { self?.handle(event) }
            self?.streamEnded()
            if scoped { scopedURL?.stopAccessingSecurityScopedResource() }
        }
    }

    func cancel() {
        runner?.cancel()
        resolve(allowed: false, always: false)
        if busy {
            phase = .failed
            status = "ABORTED"
            add("Aborted", "warn")
            remember(status: "aborted", summary: "Aborted before it finished")
            record(status: "aborted", summary: "Aborted")
        }
    }

    func respond(_ decision: ApprovalDecision) {
        resolve(allowed: decision != .deny, always: decision == .always)
    }

    /// Starts a fresh conversation: the next mission no longer knows about the earlier ones.
    func forgetConversation() {
        guard !busy else { notice = "Wait for the current mission to finish."; return }
        memory.clear()
        saveMemory()
    }

    private func remember(status: String, summary: String) {
        guard !remembered, !currentTask.isEmpty else { return }
        remembered = true
        memory.record(task: currentTask, actions: log.filter { $0.kind == "step" }.map(\.text), outcome: summary,
                      status: status, folder: folderPath)
        saveMemory()
    }

    private func saveMemory() {
        defaults.set(try? JSONEncoder().encode(memory), forKey: Keys.memory)
    }

    func clearNotice() { notice = nil }

    func clearHistory() {
        history = []
        historyStore?.save([])
    }

    func clearAllowRules() { allowRules = [] }

    // MARK: approvals

    private func ask(_ request: ApprovalRequest) async -> Bool {
        if let rule = request.rule, allowRules.contains(rule) {
            add("Auto-allowed by rule: \(rule.label)", "ok")
            return true
        }
        pendingRule = request.rule
        approval = RemoteApproval(id: request.id.uuidString, summary: request.summary, detail: request.detail, canAlwaysAllow: request.rule != nil)
        phase = .awaitingApproval
        status = "AWAITING AUTHORIZATION"
        add(request.summary, "warn")
        return await withCheckedContinuation { approvalContinuation = $0 }
    }

    private func resolve(allowed: Bool, always: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        if allowed, always, let rule = pendingRule, !allowRules.contains(rule) {
            allowRules.append(rule)
            add("Always allowed: \(rule.label)", "ok")
        }
        pendingRule = nil
        approval = nil
        phase = .working
        add(allowed ? "Authorization granted" : "Authorization denied", allowed ? "ok" : "warn")
        continuation.resume(returning: allowed)
    }

    // MARK: events

    private func handle(_ event: AgentEvent) {
        switch event {
        case .status(let text): if phase != .awaitingApproval { status = text }
        case .log(let text): add(text, "step")
        case .code(let text): code += text
        case .model: break   // the iPhone app does not show the model yet
        case .done(let text):
            phase = .done; status = "MISSION COMPLETE"; add(text, "ok")
            remember(status: "done", summary: text)
            record(status: "done", summary: text)
        case .failed(let text):
            phase = .failed; status = "MISSION FAILED"; add(text, "warn")
            remember(status: "failed", summary: text)
            record(status: "failed", summary: text)
        }
    }

    private func streamEnded() {
        if busy {
            phase = .done
            status = "MISSION COMPLETE"
            remember(status: "done", summary: "Complete")
            record(status: "done", summary: "Complete")
        }
    }

    private func add(_ text: String, _ kind: String) {
        log.append(RemoteLogLine(text: text, kind: kind))
    }

    private func record(status: String, summary: String) {
        guard !recorded, !currentTask.isEmpty else { return }
        recorded = true
        history.insert(MissionRecord(task: currentTask, provider: provider, mode: mode.rawValue, status: status,
                                     summary: String(summary.prefix(240)), folder: folderPath), at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        historyStore?.save(history)
    }
}
