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
    private let defaults: UserDefaults
    private static let pairingKey = "pairedMac"
    static let secretAccount = "pairing-secret"

    #if DEBUG
    // Launch arguments that let the simulator be driven without tapping:
    //   -tristanPairURL <link>  -tristanAutoSubmit <task>  -tristanAutoApprove YES
    private var autoSubmit: String?
    private var autoApprove = false
    private var autoSubmitted = false
    #endif

    init(defaults: UserDefaults = .standard, autoConnect: Bool = true) {
        self.defaults = defaults
        client.deviceName = UIDevice.current.name
        if let data = defaults.data(forKey: Self.pairingKey), let saved = try? JSONDecoder().decode(PairedMac.self, from: data) {
            pairing = saved
        }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        autoSubmit = value("-tristanAutoSubmit")
        autoApprove = value("-tristanAutoApprove") == "YES"
        if let link = value("-tristanPairURL") { handle(url: URL(string: link)!); return }
        #endif
        if autoConnect, pairing != nil { connect() }
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

    #if DEBUG
    /// Called when the client's state changes, to run the launch-argument automation.
    func automate() {
        if autoApprove, client.approval != nil { client.respond(.allow) }
        if let task = autoSubmit, !autoSubmitted, client.state == .connected, client.snapshot?.phase == .idle {
            autoSubmitted = true
            client.setProvider("DEMO")
            client.submit(task)
        }
    }
    #endif
}
