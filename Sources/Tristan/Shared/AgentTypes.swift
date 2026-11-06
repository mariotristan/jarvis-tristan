import Foundation

// The vocabulary every provider speaks. Shared by the Mac app and the iOS app.

/// A narrowly scoped "always allow" rule. Only produced for actions that are safe to generalise.
struct ApprovalRule: Codable, Hashable, Sendable, Identifiable {
    let key: String
    let label: String
    var id: String { key }

    private static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    private static let neverGeneralise: Set<String> = [
        "rm", "sudo", "dd", "chmod", "chown", "mv", "kill", "killall", "shred", "mkfs", "diskutil",
        "launchctl", "curl", "wget", "sh", "bash", "zsh", "eval", "exec", "ssh", "scp", "env", "xargs",
    ]

    /// File edits are allowed only inside the working folder; shell commands only by plain program name.
    static func make(tool: String, input: [String: Any], workingDirectory: URL) -> ApprovalRule? {
        if fileTools.contains(tool) {
            guard let path = (input["file_path"] ?? input["notebook_path"]) as? String else { return nil }
            guard let root = SafePath.real(workingDirectory),
                  let file = SafePath.real(URL(fileURLWithPath: path)),
                  file.hasPrefix(root + "/") else { return nil }
            return ApprovalRule(key: "\(tool)@\(root)", label: "\(tool) inside \(workingDirectory.lastPathComponent)")
        }
        if tool == "Bash", let command = input["command"] as? String {
            let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let operators = [";", "&", "|", ">", "<", "`", "$(", "\n", "\\"]
            guard !operators.contains(where: text.contains) else { return nil }
            guard let first = text.split(separator: " ").first.map(String.init),
                  first.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
                  !neverGeneralise.contains(first) else { return nil }
            return ApprovalRule(key: "Bash:\(first)", label: "Bash: \(first) …")
        }
        return nil
    }
}

struct ApprovalRequest: Identifiable, Sendable {
    let id = UUID()
    let summary: String
    let detail: String
    var rule: ApprovalRule?
}

enum AgentEvent: Sendable {
    case status(String)
    case log(String)
    case code(String)
    case done(String)
    case failed(String)
}

typealias Approver = @Sendable (ApprovalRequest) async -> Bool

protocol AgentProvider: Sendable {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent>
}
