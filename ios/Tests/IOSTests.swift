import XCTest
@testable import Tristan

@MainActor
final class IOSTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "tristan-ios-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    override func tearDown() async throws { KeychainStore.set("", account: AppModel.secretAccount) }

    func testValidLinkPairsAndStoresTheSecretInTheKeychainNotPreferences() throws {
        let defaults = freshDefaults()
        let model = AppModel(defaults: defaults, autoConnect: false)
        XCTAssertNil(model.pairing)
        let secret = PairingSecret.generate()
        let link = PairingLink(name: "Test Mac", host: "127.0.0.1", port: 59999, secret: secret)
        model.handle(url: link.url)
        XCTAssertEqual(model.pairing, PairedMac(name: "Test Mac", host: "127.0.0.1", port: 59999))
        XCTAssertEqual(KeychainStore.get(AppModel.secretAccount), PairingSecret.hex(secret))
        let stored = String(decoding: defaults.data(forKey: "pairedMac") ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.contains(PairingSecret.hex(secret)), "the secret must never be written to preferences")
        model.unpair()
    }

    func testPairingSurvivesARestartAndUnpairForgetsEverything() throws {
        let defaults = freshDefaults()
        let first = AppModel(defaults: defaults, autoConnect: false)
        first.pair(PairingLink(name: "Mac", host: "mac.local", port: 4000, secret: PairingSecret.generate()))
        first.client.disconnect()
        let second = AppModel(defaults: defaults, autoConnect: false)
        XCTAssertEqual(second.pairing?.host, "mac.local")
        second.unpair()
        XCTAssertNil(second.pairing)
        XCTAssertNil(KeychainStore.get(AppModel.secretAccount), "unpairing removes the secret")
        XCTAssertNil(AppModel(defaults: defaults, autoConnect: false).pairing)
    }

    func testBadLinksAreRejectedWithAMessage() {
        let model = AppModel(defaults: freshDefaults(), autoConnect: false)
        model.handle(url: URL(string: "tristan://pair?host=evil.com/%0A&port=1&secret=00")!)
        XCTAssertNil(model.pairing)
        XCTAssertNotNil(model.pairingError)
    }
}
