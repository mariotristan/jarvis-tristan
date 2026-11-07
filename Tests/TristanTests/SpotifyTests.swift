import XCTest
@testable import Tristan
@testable import TristanCore

/// A pretend Spotify: records every script and answers the status query from its own state.
final class FakeSpotify: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private var _volume = 80
    private var _state = "playing"
    var failure: Error?

    var scripts: [String] { lock.lock(); defer { lock.unlock() }; return _scripts }
    var volume: Int { lock.lock(); defer { lock.unlock() }; return _volume }

    func run(_ source: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        if source == SpotifyScripts.status { return "\(_state)\tSong\tArtist\t\(_volume)" }
        _scripts.append(source)
        if let range = source.range(of: "set sound volume to "), let value = Int(source[range.upperBound...]) { _volume = value }
        if source == SpotifyScripts.pause { _state = "paused" }
        if source == SpotifyScripts.play { _state = "playing" }
        return ""
    }
}

final class MusicCommandTests: XCTestCase {
    func testPhrasesMatchRegardlessOfCaseAndPunctuation() {
        XCTAssertEqual(MusicCommand.parse("Play music"), .play)
        XCTAssertEqual(MusicCommand.parse("Next song."), .next)
        XCTAssertEqual(MusicCommand.parse("Tristan, skip this song, please!"), .next)
        XCTAssertEqual(MusicCommand.parse("pause"), .pause)
        XCTAssertEqual(MusicCommand.parse("What's playing?"), .nowPlaying)
        XCTAssertEqual(MusicCommand.parse("play my focus playlist"), .focusPlaylist)
        XCTAssertEqual(MusicCommand.parse("turn it up"), .volumeUp)
        XCTAssertEqual(MusicCommand.parse("quieter"), .volumeDown)
        XCTAssertEqual(MusicCommand.parse("go back"), .previous)
    }

    func testVolumeNumbersAreParsedAndClamped() {
        XCTAssertEqual(MusicCommand.parse("volume 40"), .setVolume(40))
        XCTAssertEqual(MusicCommand.parse("set the volume to 30 percent"), .setVolume(30))
        XCTAssertEqual(MusicCommand.parse("music volume to 250"), .setVolume(100))
    }

    func testRealTasksAreNeverMistakenForMusicCommands() {
        for task in ["add a pause button to the player", "write a function to skip duplicates", "play a game of pong in python",
                     "next.js tutorial", "pause the deployment pipeline", "volume of the cube", "fix the music player component",
                     "play music in the background of the website", ""] {
            XCTAssertNil(MusicCommand.parse(task), "\"\(task)\" must not be treated as a music command")
        }
    }
}

final class SpotifyURITests: XCTestCase {
    private let id = "37i9dQZF1DXcBWIGoYBM5M"

    func testAcceptsUrisAndShareLinks() {
        XCTAssertEqual(SpotifyURI.normalize("spotify:playlist:\(id)"), "spotify:playlist:\(id)")
        XCTAssertEqual(SpotifyURI.normalize("https://open.spotify.com/playlist/\(id)?si=abc123"), "spotify:playlist:\(id)")
        XCTAssertEqual(SpotifyURI.normalize("https://open.spotify.com/intl-es/album/\(id)"), "spotify:album:\(id)")
        XCTAssertEqual(SpotifyURI.normalize("  spotify:track:\(id)\n"), "spotify:track:\(id)")
    }

    func testRejectsAnythingElseSoNothingCanBeInjected() {
        for bad in ["", "spotify:playlist:short", "spotify:playlist:\(id)\" & do shell script \"rm -rf ~\"", "spotify:radio:\(id)",
                    "https://evil.com/open.spotify.com/playlist/\(id)", "http://open.spotify.com/playlist/\(id)",
                    "https://open.spotify.com/playlist/\(id)extra", "spotify:playlist:\(id) spotify:track:\(id)"] {
            XCTAssertNil(SpotifyURI.normalize(bad), "\"\(bad)\" must be rejected")
        }
        let script = SpotifyScripts.play(uri: SpotifyURI.normalize("spotify:playlist:\(id)")!)
        XCTAssertEqual(script, #"tell application "Spotify" to play track "spotify:playlist:\#(id)""#)
    }

    func testVolumeScriptIsClamped() {
        XCTAssertTrue(SpotifyScripts.setVolume(500).hasSuffix("to 100"))
        XCTAssertTrue(SpotifyScripts.setVolume(-5).hasSuffix("to 0"))
    }
}

final class DuckerTests: XCTestCase {
    func testDucksOnFirstReasonAndRestoresOnLast() {
        var ducker = Ducker()
        XCTAssertEqual(ducker.set("speech", active: true, currentVolume: 80, playing: true), 24)
        XCTAssertNil(ducker.set("mic", active: true, currentVolume: 24, playing: true), "already ducked")
        XCTAssertNil(ducker.set("speech", active: false, currentVolume: 24, playing: true), "mic still needs quiet")
        XCTAssertEqual(ducker.set("mic", active: false, currentVolume: 24, playing: true), 80)
        XCTAssertFalse(ducker.isDucked)
    }

    func testDoesNothingWhenMusicIsNotPlaying() {
        var ducker = Ducker()
        XCTAssertNil(ducker.set("speech", active: true, currentVolume: 80, playing: false))
        XCTAssertNil(ducker.set("speech", active: false, currentVolume: 80, playing: false))
    }

    func testRespectsAVolumeTheUserChangedWhileDucked() {
        var ducker = Ducker()
        _ = ducker.set("speech", active: true, currentVolume: 80, playing: true)
        XCTAssertNil(ducker.set("speech", active: false, currentVolume: 55, playing: true), "do not override the user's change")
    }

    func testNowPlayingParsing() {
        XCTAssertEqual(NowPlaying.parse("playing\tSong\tArtist\t64")?.volume, 64)
        XCTAssertEqual(NowPlaying.parse("paused\tA\tB\t10")?.isPlaying, false)
        XCTAssertNil(NowPlaying.parse("stopped"))
        XCTAssertNil(NowPlaying.parse("garbage"))
    }
}

@MainActor
final class SpotifyControllerTests: XCTestCase {
    private func controller(_ fake: FakeSpotify, running: Bool = true) -> SpotifyController {
        SpotifyController(runner: fake, isRunning: { running }, releaseDelay: .zero)
    }

    private func eventually(_ condition: @autoclosure () -> Bool) async throws {
        for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testCommandsSendTheRightScripts() async {
        let fake = FakeSpotify()
        let music = controller(fake)
        var reply = await music.perform(.next)
        XCTAssertEqual(reply, "Next track.")
        reply = await music.perform(.pause)
        XCTAssertEqual(reply, "Paused.")
        reply = await music.perform(.setVolume(35))
        XCTAssertEqual(reply, "Volume 35 percent.")
        XCTAssertEqual(fake.scripts, [SpotifyScripts.next, SpotifyScripts.pause, SpotifyScripts.setVolume(35)])
    }

    func testVolumeUpStepsFromTheCurrentVolume() async {
        let fake = FakeSpotify()      // starts at 80
        let reply = await controller(fake).perform(.volumeUp)
        XCTAssertEqual(reply, "Volume 95 percent.")
        XCTAssertEqual(fake.volume, 95)
    }

    func testDoesNotLaunchSpotifyForControlCommands() async {
        let fake = FakeSpotify()
        let reply = await controller(fake, running: false).perform(.pause)
        XCTAssertEqual(reply, "Spotify isn't running.")
        XCTAssertTrue(fake.scripts.isEmpty, "pause must never launch Spotify")
    }

    func testFocusPlaylistNeedsAValidLink() async {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: "music.focus") }
        let fake = FakeSpotify()
        let music = controller(fake)
        defaults.removeObject(forKey: "music.focus")
        var reply = await music.perform(.focusPlaylist)
        XCTAssertTrue(reply.contains("Configuration"))
        defaults.set("not a link", forKey: "music.focus")
        reply = await music.perform(.focusPlaylist)
        XCTAssertTrue(reply.contains("Configuration"))
        XCTAssertTrue(fake.scripts.isEmpty)
        defaults.set("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=x", forKey: "music.focus")
        reply = await music.perform(.focusPlaylist)
        XCTAssertEqual(reply, "Playing your focus playlist.")
        XCTAssertEqual(fake.scripts.last, SpotifyScripts.play(uri: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"))
    }

    func testPermissionErrorsAreExplained() async {
        let fake = FakeSpotify()
        fake.failure = SpotifyError(number: -1743, message: "not authorized")
        let music = controller(fake)
        let reply = await music.perform(.next)
        XCTAssertTrue(reply.contains("Automation"), "tell the user where to grant access")
    }

    func testMusicDucksWhileSpeakingAndRestores() async throws {
        let fake = FakeSpotify()      // playing at 80
        let music = controller(fake)
        music.enabled = true
        music.setDuck("speech", active: true)
        try await eventually(fake.volume == 24)
        XCTAssertEqual(fake.volume, 24)
        music.setDuck("speech", active: false)
        try await eventually(fake.volume == 80)
        XCTAssertEqual(fake.volume, 80)
        music.enabled = false
    }

    func testDuckingCanBeSwitchedOff() async throws {
        let fake = FakeSpotify()
        let music = controller(fake)
        music.enabled = true
        music.duckingEnabled = false
        music.setDuck("speech", active: true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fake.volume, 80)
        music.enabled = false
    }

    func testSessionRoutesMusicCommandsAwayFromMissions() async throws {
        let fake = FakeSpotify()
        let session = Session(history: nil, music: controller(fake))
        session.soundsOn = false; session.voiceOn = false; session.notificationsOn = false
        session.musicOn = true
        session.provider = .azure       // would fail as a mission; a music command must not reach it
        session.submit("next song")
        try await eventually(fake.scripts.contains(SpotifyScripts.next))
        XCTAssertTrue(fake.scripts.contains(SpotifyScripts.next))
        XCTAssertEqual(session.phase, .idle, "music commands do not start missions")
        XCTAssertTrue(session.log.contains { $0.text.contains("Next track.") })
        session.musicOn = false
    }

    func testMusicCommandsAreIgnoredWhenTheFeatureIsOff() async throws {
        let fake = FakeSpotify()
        let session = Session(history: nil, music: controller(fake))
        session.soundsOn = false; session.voiceOn = false; session.notificationsOn = false
        session.musicOn = false
        session.provider = .azure
        session.submit("next song")
        try await eventually(session.phase == .failed)
        XCTAssertTrue(fake.scripts.isEmpty)
        XCTAssertEqual(session.phase, .failed, "with music off it is an ordinary task")
    }
}
