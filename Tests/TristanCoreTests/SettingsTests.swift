import XCTest
@testable import TristanCore

final class MemoryBackend: SettingsBackend {
    var values: [String: Any]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class SettingsTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tristan-settings-\(UUID().uuidString)")
            .appendingPathComponent("nested/settings.json")
    }

    func testJSONFileBackendRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let first = JSONFileBackend(url: url)
        let blob = Data([0, 1, 2, 250, 255])
        try first.set("hello", forKey: "s")
        try first.set(true, forKey: "b")
        try first.set(blob, forKey: "d")
        let second = JSONFileBackend(url: url)
        XCTAssertNil(second.unreadable)
        XCTAssertEqual(second.object(forKey: "s") as? String, "hello")
        XCTAssertEqual(second.object(forKey: "b") as? Bool, true)
        XCTAssertEqual(second.object(forKey: "d") as? Data, blob)
        try second.set(nil, forKey: "s")
        XCTAssertNil(JSONFileBackend(url: url).object(forKey: "s"))
    }

    func testSettingsSurvivesMissingFile() {
        let backend = JSONFileBackend(url: tempURL())
        XCTAssertNil(backend.object(forKey: "x"))
        let previous = Settings.backend
        defer { Settings.backend = previous }
        Settings.backend = backend
        XCTAssertNil(Settings.string("x"))
        XCTAssertFalse(Settings.bool("x"))
        XCTAssertNil(Settings.data("x"))
    }

    func testSettingsTypedAccessors() {
        let previous = Settings.backend
        defer { Settings.backend = previous }
        Settings.backend = MemoryBackend()
        Settings.set("v", forKey: "k")
        Settings.set(true, forKey: "f")
        Settings.set(Data([1]), forKey: "d")
        XCTAssertEqual(Settings.string("k"), "v")
        XCTAssertTrue(Settings.bool("f"))
        XCTAssertEqual(Settings.data("d"), Data([1]))
    }

    // MARK: - An unreadable settings file fails closed (kids mode on, never overwritten)

    /// Files that exist but are not a readable JSON object: garbage bytes, truncated JSON, JSON that is not an object,
    /// an empty file.
    private static let corruptContents: [Data] = [
        Data([0xFF, 0xFE, 0x00, 0x9B, 0x1B, 0x42]),
        Data(#"{"kidsMode": tr"#.utf8),
        Data(#"{"kidsMode": false, "ollama.model": "llama3""#.utf8),
        Data("[1, 2]".utf8),
        Data(),
    ]

    private func assertFailsClosed(_ url: URL, original: Data?, file: StaticString = #filePath, line: UInt = #line) {
        let backend = JSONFileBackend(url: url)
        XCTAssertNotNil(backend.unreadable, "should report the file as unreadable", file: file, line: line)
        let previous = Settings.backend
        defer { Settings.backend = previous }
        Settings.backend = backend
        XCTAssertNotNil(Settings.unreadable, file: file, line: line)
        XCTAssertTrue(KidsRouting.kidsModeIsOn, "kids mode must count as on", file: file, line: line)
        XCTAssertTrue(KidsRouting.mustStayLocal(kidsMode: KidsRouting.kidsModeIsOn, cloudOnce: false), file: file, line: line)
        XCTAssertThrowsError(try Settings.write(false, forKey: "kidsMode"), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains("cannot be read"), "\(error)", file: file, line: line)
        }
        XCTAssertThrowsError(try Settings.write("x", forKey: "ollama.model"), file: file, line: line)
        Settings.set(false, forKey: "kidsMode")   // the non-throwing form refuses too
        if let original {
            XCTAssertEqual(try? Data(contentsOf: url), original, "the file must not be rewritten", file: file, line: line)
        }
        XCTAssertTrue(KidsRouting.kidsModeIsOn, file: file, line: line)
    }

    func testCorruptSettingsFileFailsClosed() throws {
        for contents in Self.corruptContents {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
            assertFailsClosed(url, original: contents)
        }
    }

    /// A folder where the file should be cannot be read either.
    func testSettingsPathThatIsAFolderFailsClosed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        assertFailsClosed(url, original: nil)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    #if !os(Windows)
    func testSettingsFileWithoutReadPermissionFailsClosed() throws {
        let url = tempURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data(#"{"kidsMode":false}"#.utf8)
        try contents.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        if (try? Data(contentsOf: url)) != nil { throw XCTSkip("running with permission to read any file (root)") }
        assertFailsClosed(url, original: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), contents)
    }
    #endif

    /// A `kidsMode` that is there but not a Bool (`"true"`, `"no"`, an object) was written by something else: it reads
    /// as on. A real Bool is read as it is.
    func testNonBoolKidsModeReadsAsOn() throws {
        let previous = Settings.backend
        defer { Settings.backend = previous }
        let cases: [(String, Bool)] = [(#"{"kidsMode": "true"}"#, true), (#"{"kidsMode": "no"}"#, true),
                                       (#"{"kidsMode": {"on": false}}"#, true), (#"{"kidsMode": false}"#, false),
                                       (#"{"kidsMode": true}"#, true), (#"{"other": 1}"#, false)]
        for (json, on) in cases {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
            Settings.backend = JSONFileBackend(url: url)
            XCTAssertNil(Settings.unreadable, json)
            XCTAssertEqual(KidsRouting.kidsModeIsOn, on, json)
        }
    }

    /// The message says kids mode stays on until the file is repaired, and does not offer deleting it as the way out.
    func testUnreadableMessageSaysKidsModeStaysOn() {
        let text = SettingsError.unreadable(path: "/x/settings.json", reason: "it is not valid settings JSON").localizedDescription
        XCTAssertTrue(text.contains("Kids mode stays on until the file is repaired"), text)
        XCTAssertFalse(text.lowercased().contains("delete"), text)
    }

    /// No file yet is not an error: kids mode is off and the first write creates the file.
    func testMissingSettingsFileIsReadableAndWritable() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let previous = Settings.backend
        defer { Settings.backend = previous }
        Settings.backend = JSONFileBackend(url: url)
        XCTAssertNil(Settings.unreadable)
        XCTAssertFalse(KidsRouting.kidsModeIsOn)
        try Settings.write(true, forKey: "kidsMode")
        XCTAssertTrue(KidsRouting.kidsModeIsOn)
        XCTAssertNil(Settings.unreadable)
        try Settings.write(false, forKey: "kidsMode")
        XCTAssertFalse(KidsRouting.kidsModeIsOn)
    }

    /// The Mac's UserDefaults (and any other backend) is never "unreadable": kids mode is exactly the stored flag.
    func testOtherBackendsAreNeverUnreadable() throws {
        let previous = Settings.backend
        defer { Settings.backend = previous }
        Settings.backend = MemoryBackend()
        XCTAssertNil(Settings.unreadable)
        XCTAssertFalse(KidsRouting.kidsModeIsOn)
        Settings.set(true, forKey: "kidsMode")
        XCTAssertTrue(KidsRouting.kidsModeIsOn)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tristan-tests-\(UUID().uuidString)"))
        XCTAssertNil(UserDefaultsBackend(defaults).unreadable)
    }

    func testOllamaConfigReadsThroughSettings() {
        let previous = Settings.backend
        defer { Settings.backend = previous }
        Settings.backend = MemoryBackend(["ollama.host": " http://127.0.0.1:9999 ", "ollama.model": "llama3"])
        let config = OllamaConfig.load()
        XCTAssertEqual(config.host, "http://127.0.0.1:9999")
        XCTAssertEqual(config.model, "llama3")
    }
}
