import AppKit

struct NowPlaying: Equatable {
    var state: String       // "playing" or "paused"
    var track: String
    var artist: String
    var volume: Int

    var isPlaying: Bool { state == "playing" }

    /// Parses the tab-separated line produced by `SpotifyScripts.status`. nil when nothing is loaded.
    static func parse(_ output: String) -> NowPlaying? {
        let parts = output.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard parts.count == 4, parts[0] == "playing" || parts[0] == "paused" else { return nil }
        return NowPlaying(state: parts[0], track: parts[1], artist: parts[2], volume: Int(parts[3]) ?? 50)
    }
}

/// Short spoken or typed commands that control music instead of starting a coding mission.
/// Only whole, exact phrases match, so a real task is never mistaken for a music command.
enum MusicCommand: Equatable {
    case play, pause, next, previous, volumeUp, volumeDown, setVolume(Int), focusPlaylist, nowPlaying

    private static let phrases: [String: MusicCommand] = [
        "play music": .play, "play some music": .play, "resume music": .play, "resume": .play, "play spotify": .play,
        "resume spotify": .play, "start the music": .play, "start music": .play,
        "pause": .pause, "pause music": .pause, "pause the music": .pause, "pause spotify": .pause,
        "stop music": .pause, "stop the music": .pause,
        "next": .next, "next song": .next, "next track": .next, "skip": .next, "skip song": .next,
        "skip this song": .next, "skip track": .next,
        "previous": .previous, "previous song": .previous, "previous track": .previous, "last song": .previous,
        "go back": .previous,
        "volume up": .volumeUp, "turn it up": .volumeUp, "turn the volume up": .volumeUp, "louder": .volumeUp,
        "turn up the music": .volumeUp,
        "volume down": .volumeDown, "turn it down": .volumeDown, "turn the volume down": .volumeDown,
        "quieter": .volumeDown, "softer": .volumeDown, "turn down the music": .volumeDown,
        "play my focus playlist": .focusPlaylist, "play focus music": .focusPlaylist, "focus music": .focusPlaylist,
        "play my focus music": .focusPlaylist, "play focus playlist": .focusPlaylist,
        "whats playing": .nowPlaying, "what is playing": .nowPlaying, "what song is this": .nowPlaying,
        "whats this song": .nowPlaying, "what song is playing": .nowPlaying,
    ]

    static func parse(_ text: String) -> MusicCommand? {
        var phrase = text.lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init).joined()
        phrase = phrase.split(separator: " ").joined(separator: " ")
        for prefix in ["tristan ", "please "] where phrase.hasPrefix(prefix) { phrase = String(phrase.dropFirst(prefix.count)) }
        for suffix in [" please", " tristan"] where phrase.hasSuffix(suffix) { phrase = String(phrase.dropLast(suffix.count)) }
        if let command = phrases[phrase] { return command }
        if let match = phrase.range(of: #"^(?:set )?(?:the )?(?:music )?volume (?:to )?(\d{1,3})(?: percent)?$"#, options: .regularExpression),
           let number = Int(phrase[match].split(separator: " ").compactMap { Int($0) }.last.map(String.init) ?? "") {
            return .setVolume(min(max(number, 0), 100))
        }
        return nil
    }
}

/// Only well-formed Spotify identifiers ever reach an AppleScript, so nothing can be injected.
enum SpotifyURI {
    private static let kinds = "playlist|album|track|artist|show|episode"

    static func normalize(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = ["^spotify:(\(kinds)):([A-Za-z0-9]{22})$",
                        "^https://open\\.spotify\\.com/(?:intl-[a-z]{2}/)?(\(kinds))/([A-Za-z0-9]{22})(?:\\?[^\\s]*)?$"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let kind = Range(match.range(at: 1), in: text), let id = Range(match.range(at: 2), in: text) else { continue }
            return "spotify:\(text[kind]):\(text[id])"
        }
        return nil
    }
}

enum SpotifyScripts {
    static let status = """
    tell application "Spotify"
        if player state is stopped then return "stopped"
        return (player state as string) & tab & (name of current track) & tab & (artist of current track) & tab & (sound volume as string)
    end tell
    """
    static let launch = #"tell application "Spotify" to launch"#
    static let play = #"tell application "Spotify" to play"#
    static let pause = #"tell application "Spotify" to pause"#
    static let next = #"tell application "Spotify" to next track"#
    static let previous = #"tell application "Spotify" to previous track"#

    static func setVolume(_ value: Int) -> String {
        #"tell application "Spotify" to set sound volume to \#(min(max(value, 0), 100))"#
    }

    /// `uri` must come from `SpotifyURI.normalize`.
    static func play(uri: String) -> String {
        #"tell application "Spotify" to play track "\#(uri)""#
    }
}

struct SpotifyError: LocalizedError {
    let number: Int
    let message: String

    var errorDescription: String? {
        switch number {
        case -1743: return "Allow Tristan to control Spotify in System Settings > Privacy & Security > Automation."
        case -600: return "Spotify is not running."
        default: return "Spotify said: \(message)"
        }
    }
}

protocol ScriptRunner: Sendable {
    func run(_ source: String) async throws -> String
}

/// Runs AppleScript on one background queue (NSAppleScript is not thread-safe, and must not block the UI).
final class AppleScriptRunner: ScriptRunner, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.tristan.applescript")

    func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try Self.runBlocking(source) }) }
        }
    }

    static func runBlocking(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw SpotifyError(number: 0, message: "Could not compile the script") }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw SpotifyError(number: error["NSAppleScriptErrorNumber"] as? Int ?? 0,
                               message: error["NSAppleScriptErrorMessage"] as? String ?? "AppleScript failed")
        }
        return result.stringValue ?? ""
    }
}

/// Lowers the music while Tristan talks or listens and puts it back afterwards. Pure, so it is easy to test.
struct Ducker {
    var factor = 0.3
    private(set) var saved: Int?
    private var duckedTo: Int?
    private var reasons = Set<String>()

    var isDucked: Bool { saved != nil }

    /// Returns the volume to set now, or nil if nothing should change.
    mutating func set(_ reason: String, active: Bool, currentVolume: Int, playing: Bool) -> Int? {
        if active {
            let wasIdle = reasons.isEmpty
            reasons.insert(reason)
            guard wasIdle, playing else { return nil }
            saved = currentVolume
            duckedTo = Int(Double(currentVolume) * factor)
            return duckedTo
        }
        reasons.remove(reason)
        guard reasons.isEmpty, let original = saved else { return nil }
        let wasAtDuckedLevel = abs(currentVolume - (duckedTo ?? currentVolume)) <= 2
        saved = nil
        duckedTo = nil
        // If the user changed the volume while ducked, respect that instead of overriding it.
        return wasAtDuckedLevel ? original : nil
    }
}

/// Controls the Spotify desktop app. Never launches it unless the user explicitly asks to play.
@MainActor
final class SpotifyController: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var spotifyRunning = false
    @Published private(set) var lastError: String?

    var enabled = false {
        didSet { enabled ? startPolling() : stopPolling() }
    }
    var duckingEnabled = true

    private let runner: ScriptRunner
    private let isRunning: () -> Bool
    private let releaseDelay: Duration
    private var ducker = Ducker()
    private var poller: Task<Void, Never>?
    private var pendingRelease: [String: Task<Void, Never>] = [:]

    init(runner: ScriptRunner = AppleScriptRunner(),
         isRunning: @escaping () -> Bool = {
             NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
         },
         releaseDelay: Duration = .milliseconds(600)) {
        self.runner = runner
        self.isRunning = isRunning
        self.releaseDelay = releaseDelay
    }

    // MARK: state

    func refresh() async {
        spotifyRunning = isRunning()
        guard spotifyRunning else { nowPlaying = nil; return }
        do {
            nowPlaying = NowPlaying.parse(try await runner.run(SpotifyScripts.status))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopPolling() {
        poller?.cancel()
        poller = nil
        nowPlaying = nil
        lastError = nil
    }

    // MARK: commands

    /// Runs a command and returns a short sentence describing what happened (also used for the spoken reply).
    func perform(_ command: MusicCommand) async -> String {
        switch command {
        case .play:
            guard await ensureRunning() else { return "I couldn't start Spotify." }
            return await run(SpotifyScripts.play, done: "Playing.")
        case .pause:
            guard isRunning() else { return "Spotify isn't running." }
            return await run(SpotifyScripts.pause, done: "Paused.")
        case .next:
            guard isRunning() else { return "Spotify isn't running." }
            return await run(SpotifyScripts.next, done: "Next track.")
        case .previous:
            guard isRunning() else { return "Spotify isn't running." }
            return await run(SpotifyScripts.previous, done: "Previous track.")
        case .volumeUp, .volumeDown:
            guard isRunning() else { return "Spotify isn't running." }
            await refresh()
            let step = command == .volumeUp ? 15 : -15
            let target = min(max((nowPlaying?.volume ?? 50) + step, 0), 100)
            return await run(SpotifyScripts.setVolume(target), done: "Volume \(target) percent.")
        case .setVolume(let value):
            guard isRunning() else { return "Spotify isn't running." }
            return await run(SpotifyScripts.setVolume(value), done: "Volume \(min(max(value, 0), 100)) percent.")
        case .focusPlaylist:
            guard let uri = SpotifyURI.normalize(UserDefaults.standard.string(forKey: "music.focus") ?? "") else {
                return "Set a focus playlist in Configuration first."
            }
            guard await ensureRunning() else { return "I couldn't start Spotify." }
            return await run(SpotifyScripts.play(uri: uri), done: "Playing your focus playlist.")
        case .nowPlaying:
            await refresh()
            guard let playing = nowPlaying else { return "Nothing is playing." }
            return "\(playing.isPlaying ? "Now playing" : "Paused on") \(playing.track) by \(playing.artist)."
        }
    }

    func togglePlayPause() async {
        _ = await perform(nowPlaying?.isPlaying == true ? .pause : .play)
    }

    func setVolume(_ value: Int) async {
        _ = await perform(.setVolume(value))
    }

    private func run(_ script: String, done: String) async -> String {
        do {
            _ = try await runner.run(script)
            lastError = nil
            await refresh()
            return done
        } catch {
            lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

    /// Spotify is only launched because the user explicitly asked to play something.
    private func ensureRunning() async -> Bool {
        if isRunning() { return true }
        _ = try? await runner.run(SpotifyScripts.launch)
        for _ in 0..<20 where !isRunning() { try? await Task.sleep(for: .milliseconds(250)) }
        guard isRunning() else { return false }
        try? await Task.sleep(for: .seconds(1.5))   // let it finish starting
        return true
    }

    // MARK: ducking

    func setDuck(_ reason: String, active: Bool) {
        guard enabled, duckingEnabled || !active else { return }
        pendingRelease[reason]?.cancel()
        if active {
            Task { await applyDuck(reason, active: true) }
        } else {
            // A short delay avoids a volume flicker when one spoken line follows another.
            pendingRelease[reason] = Task { [weak self, releaseDelay] in
                try? await Task.sleep(for: releaseDelay)
                guard !Task.isCancelled else { return }
                await self?.applyDuck(reason, active: false)
            }
        }
    }

    private func applyDuck(_ reason: String, active: Bool) async {
        await refresh()
        guard let playing = nowPlaying ?? (ducker.isDucked ? NowPlaying(state: "paused", track: "", artist: "", volume: 0) : nil) else { return }
        if let target = ducker.set(reason, active: active, currentVolume: playing.volume, playing: playing.isPlaying) {
            _ = try? await runner.run(SpotifyScripts.setVolume(target))
            await refresh()
        }
    }

    /// Best effort at app quit: never leave the music turned down.
    func restoreVolumeNow() {
        guard let original = ducker.saved else { return }
        _ = try? AppleScriptRunner.runBlocking(SpotifyScripts.setVolume(original))
    }
}
