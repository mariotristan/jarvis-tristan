import ArgumentParser
import Foundation
import TristanCore
#if os(Windows)
import ucrt
import WinSDK
#endif

/// What commands need from the outside world, injectable so tests need no terminal, Keychain or real provider.
struct CLIEnvironment {
    /// A person can answer prompts (stdin is a terminal).
    var interactive: Bool
    /// Reads a PIN without echo after showing `prompt`; nil when nothing could be read.
    var readPIN: (String) -> String?
    var makeProvider: (CLIProvider, ApprovalMode) -> AgentProvider
    /// Whether Ctrl+C handling is installed (off in tests).
    var installInterrupt: Bool
    /// The history file (`HistoryStore`), shared with the Mac app on macOS.
    var historyURL: URL
    /// The running-missions registry behind `tristan sessions`.
    var sessions: SessionRegistry
    /// Reads one answer to an approval prompt (a line from stdin); tests script the answers.
    var readAnswer: () -> String? = { readLine() }
    /// Reads a secret without echo after showing `prompt` (`tristan secret set`); nil when nothing could be read.
    var readSecret: (String) -> String? = { PINPrompt.read($0, trim: false) }

    static var live: CLIEnvironment {
        CLIEnvironment(interactive: Terminal.inputIsTerminal, readPIN: { PINPrompt.read($0) },
                       makeProvider: { $0.make(mode: $1) }, installInterrupt: true,
                       historyURL: CLIPaths.historyURL, sessions: .live)
    }
}

enum CLIPaths {
    /// `%APPDATA%\Tristan\history.json` on Windows, the Mac app's own file on macOS, else `~/.config/tristan/history.json`.
    static var historyURL: URL {
        #if os(Windows)
        return WindowsAppData.directory.appendingPathComponent("history.json")
        #elseif os(macOS)
        return HistoryStore.defaultURL
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tristan/history.json")
        #endif
    }
}

/// Reads a PIN from the terminal with echo turned off.
enum PINPrompt {
    /// `trim: false` returns the line as typed (the secret prompt checks it for invisible characters itself).
    static func read(_ prompt: String, trim: Bool = true) -> String? {
        Terminal.writeError(prompt)
        defer { Terminal.writeError("\n") }
        #if os(Windows)
        let handle = GetStdHandle(DWORD(STD_INPUT_HANDLE))
        var mode: DWORD = 0
        let changed = GetConsoleMode(handle, &mode) && SetConsoleMode(handle, mode & ~DWORD(ENABLE_ECHO_INPUT))
        defer { if changed { _ = SetConsoleMode(handle, mode) } }
        #else
        var original = termios()
        let changed = tcgetattr(0, &original) == 0
        if changed {
            var quiet = original
            quiet.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(0, TCSAFLUSH, &quiet)
        }
        defer { if changed { tcsetattr(0, TCSAFLUSH, &original) } }
        #endif
        let line = readLine()   // without its line ending
        return trim ? line?.trimmingCharacters(in: .whitespacesAndNewlines) : line
    }
}

/// `tristan kids on|off|set-pin|status`: the Mac app's kids mode (same `kidsMode` setting and parent PIN).
struct KidsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kids",
        abstract: "Kids mode: only the local model (Ollama) answers. Set a PIN first (`kids set-pin`); the PIN is needed to leave it.",
        subcommands: [KidsOn.self, KidsOff.self, KidsSetPIN.self, KidsStatus.self])
}

enum Kids {
    static let key = "kidsMode"
    static let noPINMessage = "Kids mode is on without a PIN. Ask a parent to change it in the Tristan app."
    static var isOn: Bool { Settings.bool(key) }

    static func refuse(_ message: String, _ code: ExitCode = .usage) -> ExitCode {
        Terminal.writeError(message + "\n")
        return code
    }

    /// Asks for the parent PIN. Nil when it was entered correctly, else the exit code to stop with.
    static func askParentPIN(_ environment: CLIEnvironment, purpose: String) -> ExitCode? {
        guard environment.interactive else {
            return refuse("A parent PIN is needed \(purpose), and there is no terminal to ask it in. Nothing was changed.")
        }
        guard let entered = environment.readPIN("Parent PIN: ") else {
            return refuse("No PIN was entered. Nothing was changed.", .failed)
        }
        return ParentPIN.matches(entered) ? nil : refuse("Wrong PIN. Nothing was changed.", .failed)
    }

    /// Settings and secrets may only change with the parent PIN while kids mode is on, exactly like `kids off`.
    /// Nil to go ahead, else the exit code to stop with (nothing has been changed).
    static func guardChange(_ environment: CLIEnvironment, purpose: String) -> ExitCode? {
        guard isOn else { return nil }
        guard ParentPIN.isSet else { return refuse(noPINMessage) }
        return askParentPIN(environment, purpose: purpose)
    }
}

struct KidsOn: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(commandName: "on", abstract: "Turn kids mode on.")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        guard ParentPIN.isSet else { return Kids.refuse("Set a PIN first with `tristan kids set-pin`.") }
        Settings.set(true, forKey: Kids.key)
        Terminal.writeOutput("Kids mode is on.\n")
        return .ok
    }
}

struct KidsOff: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Turn kids mode off (asks for the parent PIN).")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        guard Kids.isOn else { Terminal.writeOutput("Kids mode is off.\n"); return .ok }
        guard ParentPIN.isSet else { return Kids.refuse(Kids.noPINMessage) }
        if let stop = Kids.askParentPIN(environment, purpose: "to turn kids mode off") { return stop }
        Settings.set(false, forKey: Kids.key)
        Terminal.writeOutput("Kids mode is off.\n")
        return .ok
    }
}

struct KidsSetPIN: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(
        commandName: "set-pin",
        abstract: "Set or change the parent PIN (\(ParentPIN.minimumLength) or more digits; asks for the current one first).")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        if Kids.isOn && !ParentPIN.isSet { return Kids.refuse(Kids.noPINMessage) }
        guard environment.interactive else {
            return Kids.refuse("Setting a PIN needs a terminal to type it in. Nothing was changed.")
        }
        if ParentPIN.isSet, let stop = Kids.askParentPIN(environment, purpose: "to change it") { return stop }
        guard let new = environment.readPIN("New PIN: ") else { return Kids.refuse("No PIN was entered. Nothing was changed.", .failed) }
        guard ParentPIN.valid(new) else {
            return Kids.refuse("The PIN must be at least \(ParentPIN.minimumLength) digits, numbers only. Nothing was changed.")
        }
        guard environment.readPIN("Repeat the new PIN: ") == new else {
            return Kids.refuse("The two PINs differ. Nothing was changed.")
        }
        guard ParentPIN.set(new) else { return Kids.refuse("The PIN could not be saved.", .failed) }
        Terminal.writeOutput("Parent PIN saved.\n")
        return .ok
    }
}

struct KidsStatus: ParsableCommand, CLICommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether kids mode is on and a PIN is set.")

    func execute(environment: CLIEnvironment) async -> ExitCode {
        Terminal.writeOutput("Kids mode: \(Kids.isOn ? "on" : "off")\nParent PIN: \(ParentPIN.isSet ? "set" : "not set")\n")
        return .ok
    }
}

extension RunCommand {
    /// Kids-mode rules for this run, read from `Settings` now. Nil to go ahead, else the exit code to stop with
    /// (nothing has been started by then).
    func kidsRefusal(_ environment: CLIEnvironment) -> ExitCode? {
        guard Kids.isOn else { return nil }
        if yolo || yesRoutine {
            return Kids.refuse("Kids mode is on: every action asks, so --yes-routine and --yolo are not allowed.")
        }
        guard provider != .ollama else { return nil }   // an allowlist: any provider added later is refused too
        let name = provider.rawValue
        guard allowCloud else {
            return Kids.refuse("Kids mode is on: only Ollama answers, so \(name) is refused. A parent can allow one run with --allow-cloud.")
        }
        guard ParentPIN.isSet else {
            return Kids.refuse("Kids mode is on and no parent PIN is set, so --allow-cloud is refused. Run `tristan kids set-pin` first.")
        }
        // Every refusal of a run in kids mode is a usage error, a wrong PIN included.
        return Kids.askParentPIN(environment, purpose: "to allow \(name) for this one run").map { _ in ExitCode.usage }
    }
}
