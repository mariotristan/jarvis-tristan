import Foundation
import TristanCore

/// The process exit status of `tristan`.
enum ExitCode: Int32 {
    case ok = 0
    /// The mission failed (or ended without finishing).
    case failed = 1
    /// Bad arguments.
    case usage = 2
    /// The mission ended, but at least one action was denied.
    case denied = 3
}

/// What one event prints: log lines as `> text`, code as is, status lines and failures on stderr.
func render(_ event: AgentEvent) -> (stdout: String?, stderr: String?) {
    switch event {
    case .status(let text): return (nil, "[\(text)]\n")
    case .log(let text): return ("> \(text)\n", nil)
    case .code(let text): return (text, nil)
    case .done(let text): return ("Done: \(text)\n", nil)
    case .failed(let text): return (nil, "Failed: \(text)\n")
    }
}

enum Mission {
    /// Runs one mission to the end and returns its exit status: `.ok` on done, `.failed` on a failure or when the
    /// stream ends without either, and `.denied` when it ended but something was denied (the denial usually caused
    /// any failure). Approvals run off the concurrency pool because answering blocks on the terminal.
    static func run(provider: AgentProvider, task: String, folder: URL, approver: TerminalApprover,
                    stdout: (String) -> Void, stderr: (String) -> Void) async -> ExitCode {
        await runReporting(provider: provider, task: task, folder: folder, approver: approver, stdout: stdout, stderr: stderr).code
    }

    /// Like `run`, and also returns the final done/failed event's text (nil when the stream ended without one).
    static func runReporting(provider: AgentProvider, task: String, folder: URL, approver: TerminalApprover,
                             stdout: (String) -> Void, stderr: (String) -> Void) async -> (code: ExitCode, final: (status: String, text: String)?) {
        var outcome: ExitCode?
        var final: (status: String, text: String)?
        var lastStatus: String?
        var atLineStart = true
        let events = provider.run(task: task, workingDirectory: folder) { request in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: approver.approve(request)) }
            }
        }
        for await event in events {
            var isCode = false
            switch event {
            case .status(let text):
                if text == lastStatus { continue }   // Copilot repeats RESPONDING for every line
                lastStatus = text
            case .code: isCode = true
            case .done(let text): outcome = .ok; final = ("done", text)
            case .failed(let text): outcome = .failed; final = ("failed", text)
            case .log: break
            }
            let (out, err) = render(event)
            // Streamed code may stop mid-line; anything else starts on a fresh line.
            if !atLineStart, err != nil || !isCode {
                stdout("\n")
                atLineStart = true
            }
            if let out, !out.isEmpty {
                stdout(out)
                atLineStart = out.hasSuffix("\n")
            }
            if let err { stderr(err) }
        }
        if !atLineStart { stdout("\n") }
        guard let outcome else { return (.failed, final) }
        return (approver.denials > 0 ? .denied : outcome, final)
    }
}
