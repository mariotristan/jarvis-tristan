import Foundation

/// Builds the `copilot` command line. Kept separate so the permission mapping can be tested without launching anything.
///
/// Copilot's headless mode (`-p`) cannot ask per action; it only honours `--allow-tool`, `--deny-tool` and
/// `--allow-all-tools` (denials always win). Approval modes therefore map like this:
/// - ASK: one up-front approval, then all tools are allowed except the deny list.
/// - AUTO: file writes and a short list of routine commands are allowed; anything else is refused by the CLI.
/// - YOLO: everything is allowed, including the commands the other modes deny.
enum CopilotArguments {
    static let deniedShell = ["rm", "sudo", "dd", "chmod", "chown", "mv", "kill", "killall", "shred", "mkfs", "diskutil",
                              "launchctl", "curl", "wget", "ssh", "scp", "git push", "git reset"]
    static let routineShell = ["git status", "git diff", "git log", "git add", "git commit", "ls", "cat", "pwd", "grep",
                               "head", "tail", "wc", "echo", "mkdir", "touch", "swift build", "swift test", "npm test", "npm run"]

    /// `logDirectory` gives this run its own log folder, so several Copilot sessions running at once never write to the
    /// same place.
    static func make(task: String, mode: ApprovalMode, model: String, logDirectory: String? = nil) -> [String] {
        var args = ["-p", task, "--no-color", "--stream", "on", "--disallow-temp-dir"]
        if let logDirectory { args += ["--log-dir", logDirectory] }
        if !model.isEmpty { args += ["--model", model] }
        switch mode {
        case .yolo:
            args.append("--allow-all-tools")
        case .ask:
            args.append("--allow-all-tools")
            args += denyRules
        case .auto:
            args += ["--allow-tool", "write"]
            for command in routineShell { args += ["--allow-tool", "shell(\(command):*)"] }
            args += denyRules
        }
        return args
    }

    private static var denyRules: [String] {
        deniedShell.flatMap { ["--deny-tool", "shell(\($0):*)"] }
    }

    /// The CLI colours output even when asked not to in some versions, so strip escape codes defensively.
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}

/// Drives the GitHub Copilot CLI (`copilot -p`) and streams its output into the HUD.
struct CopilotProvider: AgentProvider {
    var mode: ApprovalMode = .ask
    var model: String = UserDefaults.standard.string(forKey: "copilot.model") ?? ""
    /// Tests replace the launch command so no real CLI is needed.
    var launchOverride: (@Sendable ([String]) -> (executable: URL, arguments: [String]))?

    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent> {
        AsyncStream { c in
            let process = Process()
            let worker = Task {
                if mode == .ask {
                    c.yield(.status("AWAITING AUTHORIZATION"))
                    let ok = await approve(ApprovalRequest(
                        summary: "Run Copilot CLI with its tools allowed?",
                        detail: "Copilot cannot ask before each action when run headlessly. It will be able to edit files and run commands in \(workingDirectory.path). rm, sudo, curl, ssh, git push and similar stay blocked."))
                    guard ok else { c.yield(.failed("Denied by operator")); c.finish(); return }
                } else {
                    c.yield(.log("Approval mode \(mode.rawValue): mapped to Copilot's tool permissions"))
                }

                let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-copilot-logs-\(UUID().uuidString.prefix(8))")
                try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: logDirectory) }
                let arguments = CopilotArguments.make(task: task, mode: mode, model: model, logDirectory: logDirectory.path)
                if let override = launchOverride {
                    let launch = override(arguments)
                    process.executableURL = launch.executable
                    process.arguments = launch.arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["copilot"] + arguments
                }
                process.currentDirectoryURL = workingDirectory
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                env["NO_COLOR"] = "1"
                process.environment = env
                let out = Pipe()
                let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("tristan-copilot-\(UUID().uuidString.prefix(8)).err")
                FileManager.default.createFile(atPath: errFile.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: errFile) }
                process.standardOutput = out
                process.standardError = (try? FileHandle(forWritingTo: errFile)) ?? FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do { try process.run() } catch {
                    c.yield(.failed("Could not launch the Copilot CLI: \(error.localizedDescription). Install it with `npm install -g @github/copilot`."))
                    c.finish(); return
                }
                c.yield(.status("ONLINE"))
                c.yield(.log("Copilot CLI started"))

                var transcript = ""
                do {
                    for try await rawLine in out.fileHandleForReading.bytes.lines {
                        let line = CopilotArguments.stripANSI(rawLine)
                        transcript += line + "\n"
                        c.yield(.status("RESPONDING"))
                        c.yield(.code(line + "\n"))
                    }
                } catch {}
                process.waitUntilExit()

                if Task.isCancelled { c.finish(); return }
                if process.terminationStatus == 0 {
                    let summary = transcript.split(separator: "\n\n").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    c.yield(.done(summary.isEmpty ? "Copilot finished" : String(summary.suffix(240))))
                } else {
                    let stderr = ((try? String(contentsOf: errFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    c.yield(.failed(stderr.isEmpty ? "Copilot CLI exited with status \(process.terminationStatus). Is it logged in? Run `copilot` once to sign in."
                                                   : String(CopilotArguments.stripANSI(stderr).suffix(300))))
                }
                c.finish()
            }
            c.onTermination = { _ in
                worker.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }
}
