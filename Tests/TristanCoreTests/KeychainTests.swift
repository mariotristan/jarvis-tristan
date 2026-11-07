import XCTest
@testable import TristanCore

/// `KeychainStore` round trips. On Windows they use the real Credential Manager (a unique account per run, removed
/// afterwards); on the Mac they use the in-memory store so tests never touch the login Keychain.
final class KeychainTests: XCTestCase {
    private var account = ""

    override func setUp() {
        account = "test.keychain.\(UUID().uuidString)"
        #if os(Windows)
        NoKeychain.enabled = false
        #else
        NoKeychain.enabled = true
        #endif
    }

    override func tearDown() {
        KeychainStore.set("", account: account)
        NoKeychain.enabled = false
    }

    func testSetGetDeleteRoundTrip() {
        XCTAssertNil(KeychainStore.get(account))
        XCTAssertTrue(KeychainStore.set("s3cr3t \u{e9} \u{1F642}", account: account))
        XCTAssertEqual(KeychainStore.get(account), "s3cr3t \u{e9} \u{1F642}")
        XCTAssertTrue(KeychainStore.set("replaced", account: account))
        XCTAssertEqual(KeychainStore.get(account), "replaced")
    }

    func testEmptyValueDeletes() {
        XCTAssertTrue(KeychainStore.set("x", account: account))
        XCTAssertTrue(KeychainStore.set("", account: account))
        XCTAssertNil(KeychainStore.get(account), "an empty value removes it")
        XCTAssertTrue(KeychainStore.set("", account: account), "removing nothing is not a failure")
    }

    #if os(Windows)
    /// Credential Manager holds at most 2,560 bytes per secret; a bigger value is refused and the old one stays.
    func testCredentialManagerSizeLimit() {
        let largest = String(repeating: "a", count: 2560)
        XCTAssertTrue(KeychainStore.set(largest, account: account))
        XCTAssertEqual(KeychainStore.get(account), largest)
        XCTAssertFalse(KeychainStore.set(largest + "b", account: account), "2,561 bytes must be refused")
        XCTAssertEqual(KeychainStore.get(account), largest, "a refused write leaves the old value")
    }
    #endif

    func testCredentialManagerTargetName() {
        XCTAssertEqual(KeychainStore.target("azure.apiKey"), "com.tristan.app/azure.apiKey")
    }
}

// Moved from Tests/TristanTests/KidsModeTests.swift so the Windows CI runs it.
final class NoKeychainTests: XCTestCase {
    override func tearDown() { NoKeychain.enabled = false }

    func testDemoModeKeepsSecretsInMemoryAndNeverTouchesTheKeychain() {
        let account = "test.nokeychain.\(UUID().uuidString)"
        NoKeychain.enabled = true
        XCTAssertTrue(KeychainStore.set("secret", account: account))
        XCTAssertEqual(KeychainStore.get(account), "secret")
        XCTAssertTrue(KeychainStore.set("", account: account))
        XCTAssertNil(KeychainStore.get(account), "an empty value removes it")

        XCTAssertTrue(KeychainStore.set("only in memory", account: account))
        NoKeychain.enabled = false
        XCTAssertNil(KeychainStore.get(account), "nothing reached the real Keychain")
    }
}
