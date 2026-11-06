import Foundation
import Combine

/// What the mission screen talks to. It is either the Mac (remote) or this device (standalone), and the screens
/// do not need to know which.
@MainActor
final class MissionModel: ObservableObject {
    enum Mode: String { case remote, standalone }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appMode") }
    }

    let remote: RemoteClient
    let local: StandaloneEngine
    private var bag = Set<AnyCancellable>()

    init(remote: RemoteClient, local: StandaloneEngine, mode: Mode? = nil) {
        self.remote = remote
        self.local = local
        self.mode = mode ?? Mode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .remote
        // Re-publish whatever the active source changes.
        remote.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        local.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    private var standalone: Bool { mode == .standalone }

    var snapshot: RemoteSnapshot? { standalone ? local.snapshot : remote.snapshot }
    var log: [RemoteLogLine] { standalone ? local.log : remote.log }
    var code: String { standalone ? local.code : remote.code }
    var approval: RemoteApproval? { standalone ? local.approval : remote.approval }
    var history: [MissionRecord] { standalone ? local.history : remote.history }
    var notice: String? { standalone ? local.notice : remote.notice }
    /// A standalone device is always "connected" to itself.
    var state: RemoteClient.State { standalone ? .connected : remote.state }
    var deviceName: String { remote.deviceName }

    func submit(_ task: String) { standalone ? local.submit(task) : remote.submit(task) }
    func cancel() { standalone ? local.cancel() : remote.cancel() }
    func respond(_ decision: ApprovalDecision) { standalone ? local.respond(decision) : remote.respond(decision) }
    func setProvider(_ name: String) { if standalone { if !local.busy { local.provider = name } } else { remote.setProvider(name) } }
    func setMode(_ name: String) {
        if standalone { if !local.busy, let value = ApprovalMode(rawValue: name), value != .yolo { local.mode = value } } else { remote.setMode(name) }
    }
    func setFolder(_ path: String) { standalone ? local.setFolder(path: path) : remote.setFolder(path) }
    func music(_ command: String) { if !standalone { remote.music(command) } }
    func requestHistory() { if !standalone { remote.requestHistory() } }
    func clearNotice() { standalone ? local.clearNotice() : remote.clearNotice() }
}
