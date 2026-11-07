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
        first.set("hello", forKey: "s")
        first.set(true, forKey: "b")
        first.set(blob, forKey: "d")
        let second = JSONFileBackend(url: url)
        XCTAssertEqual(second.object(forKey: "s") as? String, "hello")
        XCTAssertEqual(second.object(forKey: "b") as? Bool, true)
        XCTAssertEqual(second.object(forKey: "d") as? Data, blob)
        second.set(nil, forKey: "s")
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

    func testOllamaConfigReadsThroughSettings() {
        let previous = Settings.backend
        defer { Settings.backend = previous }
        Settings.backend = MemoryBackend(["ollama.host": " http://127.0.0.1:9999 ", "ollama.model": "llama3"])
        let config = OllamaConfig.load()
        XCTAssertEqual(config.host, "http://127.0.0.1:9999")
        XCTAssertEqual(config.model, "llama3")
    }
}
