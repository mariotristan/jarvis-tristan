import ArgumentParser
import Foundation
import TristanCore
#if os(Windows)
import ucrt
import WinSDK
#endif

/// `tristan`: the root command. It only groups the subcommands.
struct TristanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tristan",
        abstract: "Run coding-agent missions from the terminal and approve their actions here.",
        subcommands: [RunCommand.self, ProvidersCommand.self, KidsCommand.self])
}

package enum CLI {
    /// The whole program. `--mcp-permission <endpoint>` (Claude Code starting this program as its approval shim) is
    /// handled before any argument parsing, exactly as the Mac app does; its two tokens come from the environment.
    package static func main(_ arguments: [String] = CommandLine.arguments) async -> Never {
        if let endpoint = shimEndpoint(arguments) {
            let environment = ProcessInfo.processInfo.environment
            PermissionShim.run(endpoint: endpoint,
                               token: environment[ApprovalTransport.tokenEnvironmentKey],
                               serverToken: environment[ApprovalTransport.serverTokenEnvironmentKey])
        }
        #if os(Windows)
        SetConsoleOutputCP(65001)   // UTF-8, so streamed answers and file names print as written
        #endif
        #if os(macOS)
        // Share settings (models, endpoints, allow rules, kids mode) with the Mac app instead of a `tristan-cli` domain.
        if let shared = UserDefaults(suiteName: "com.tristan.app") { Settings.backend = UserDefaultsBackend(shared) }
        #endif

        switch parse(Array(arguments.dropFirst())) {
        case .run(let command):
            exit(await command.execute().rawValue)
        case .stop(let code, let message):
            if code == .ok { Terminal.writeOutput(message + "\n") } else { Terminal.writeError(message + "\n") }
            exit(code.rawValue)
        }
    }

    /// The endpoint when this process was started as the approval shim: `--mcp-permission <endpoint>` as the very
    /// first arguments (how Claude Code starts it). Anywhere else, e.g. among a task's words, it is not the shim.
    static func shimEndpoint(_ arguments: [String]) -> String? {
        guard arguments.count >= 3, arguments[1] == "--mcp-permission" else { return nil }
        return arguments[2]
    }

    enum Parsed {
        case run(CLICommand)
        /// Help, or an argument error: print `message` and exit with `code`.
        case stop(ExitCode, message: String)
    }

    /// Parses the arguments (without the program name). Bare `tristan` prints help as a usage error.
    static func parse(_ arguments: [String]) -> Parsed {
        do {
            let command = try TristanCommand.parseAsRoot(arguments)
            if let runnable = command as? CLICommand { return .run(runnable) }
            if command is TristanCommand { return .stop(.usage, message: TristanCommand.helpMessage()) }
            var other = command
            try other.run()   // `--help` and `help <command>` throw a clean exit carrying the help text
            return .stop(.ok, message: "")
        } catch {
            return .stop(exitCode(for: error), message: TristanCommand.fullMessage(for: error))
        }
    }

    /// Help and version requests are `.ok`; every parse or validation error is `.usage`.
    static func exitCode(for error: Error) -> ExitCode {
        let code = TristanCommand.exitCode(for: error)
        if code == ArgumentParser.ExitCode.success { return .ok }
        if code == ArgumentParser.ExitCode.validationFailure { return .usage }
        return .failed
    }
}

/// Unbuffered writes, so streamed text appears as it arrives and stdout and stderr keep their order.
enum Terminal {
    /// Test hook: when set, standard output goes here instead of the terminal.
    nonisolated(unsafe) static var capture: ((String) -> Void)?
    static func writeOutput(_ text: String) {
        if let capture { capture(text); return }
        FileHandle.standardOutput.write(Data(text.utf8))
    }
    static func writeError(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }

    /// True when a person can answer prompts: stdin is a terminal (not a pipe, file or /dev/null).
    static var inputIsTerminal: Bool {
        #if os(Windows)
        return _isatty(0) != 0   // descriptor 0 is stdin; the C `stdin` macro does not import into Swift
        #else
        return isatty(0) != 0
        #endif
    }
}

/// Ctrl+C: cancel the mission, stop every provider process tree, print "Cancelled" and exit with status 130.
/// A second Ctrl+C exits at once.
enum Interrupt {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cancel: (() -> Void)?
    nonisolated(unsafe) private static var fired = false
    nonisolated(unsafe) private static var installed = false
    private static let ended = DispatchSemaphore(value: 0)
    #if !os(Windows)
    nonisolated(unsafe) private static var source: DispatchSourceSignal?
    #endif

    static func install(cancel: @escaping () -> Void) {
        lock.lock()
        self.cancel = cancel
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }
        #if os(Windows)
        SetConsoleCtrlHandler({ kind in
            guard kind == DWORD(CTRL_C_EVENT) || kind == DWORD(CTRL_BREAK_EVENT) else { return false }
            Interrupt.fire()
            return true
        }, true)
        #else
        // A real (empty) handler rather than SIG_IGN: an ignored signal would stay ignored in every child we start.
        signal(SIGINT) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { Interrupt.fire() }
        source.resume()
        self.source = source
        #endif
    }

    /// Called when the mission's task has returned. If Ctrl+C is being handled, waits for it to exit the process.
    static func missionEnded() {
        ended.signal()
        lock.lock()
        let cancelling = fired
        lock.unlock()
        if cancelling { while true { Thread.sleep(forTimeInterval: 60) } }
    }

    static func fire() {
        lock.lock()
        let again = fired
        fired = true
        let cancel = self.cancel
        lock.unlock()
        if again { exit(130) }
        Terminal.writeError("\nCancelling...\n")
        cancel?()
        // The cancelled stream stops its own process tree; this catches any box the stream did not reach.
        ProcessBox.terminateAll()
        _ = ended.wait(timeout: .now() + 3)
        Terminal.writeError("Cancelled\n")
        exit(130)
    }
}
