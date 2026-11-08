import Foundation

// The vocabulary every provider speaks. Shared by the Mac app and the iOS app.

/// A narrowly scoped "always allow" rule. Only produced for actions that are safe to generalise.
package struct ApprovalRule: Codable, Hashable, Sendable, Identifiable {
    package let key: String
    package let label: String
    package var id: String { key }

    package init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    private static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// File edits are allowed only inside the working folder; shell commands only by plain program name.
    static func make(tool: String, input: [String: Any], workingDirectory: URL) -> ApprovalRule? {
        make(tool: tool, input: input, workingDirectory: workingDirectory, host: .current)
    }

    /// `host` is the platform the command runs on; tests pass `.windows` to check Windows rules on the Mac.
    static func make(tool: String, input: [String: Any], workingDirectory: URL, host: PathFlavor) -> ApprovalRule? {
        if fileTools.contains(tool) {
            guard let path = (input["file_path"] ?? input["notebook_path"]) as? String else { return nil }
            guard PathContainment.form(of: path, flavor: host) != .rejected,
                  let root = SafePath.real(workingDirectory),
                  let file = SafePath.real(URL(fileURLWithPath: path)),
                  PathContainment.isStrictlyInside(root: root, path: file, flavor: host) else { return nil }
            return ApprovalRule(key: "\(tool)@\(root)", label: "\(tool) inside \(workingDirectory.lastPathComponent)")
        }
        if let flavor = ShellFlavor(ruleToolName: tool), let command = input["command"] as? String {
            // PowerShell is case-insensitive throughout. Claude Code's Bash tool on Windows runs Git Bash on a
            // case-insensitive file system where `.exe` resolves and `powershell`/`cmd` are a word away, so on a
            // Windows host Bash commands use the Windows names too. On the Mac, Bash is exactly today's check.
            let windowsRules = flavor == .powershell || host == .windows
            let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let haystack = flavor == .powershell ? text.lowercased() : text
            guard !flavor.operators.contains(where: haystack.contains) else { return nil }
            if windowsRules {
                guard !ShellFlavor.hasUnsafeCharacter(text), !ShellFlavor.hasEncodedCommandFlag(text) else { return nil }
            }
            let never = windowsRules ? ShellFlavor.powershell.neverGeneralise : flavor.neverGeneralise
            guard let first = text.split(separator: " ").first.map(String.init),
                  let name = ShellFlavor.programName(first, windowsRules: windowsRules),
                  !never.contains(name), !never.contains(windowsRules ? first.lowercased() : first) else { return nil }
            return ApprovalRule(key: "\(tool):\(name)", label: "\(tool): \(name) …")
        }
        return nil
    }
}

package struct ApprovalRequest: Identifiable, Sendable {
    package let id = UUID()
    package let summary: String
    package let detail: String
    package var rule: ApprovalRule?

    package init(summary: String, detail: String, rule: ApprovalRule? = nil) {
        self.summary = summary
        self.detail = detail
        self.rule = rule
    }
}

package enum AgentEvent: Sendable {
    case status(String)
    case log(String)
    case code(String)
    case done(String)
    /// The model the provider reports it is using (known once a mission has started).
    case model(String)
    case failed(String)
}

package typealias Approver = @Sendable (ApprovalRequest) async -> Bool

package protocol AgentProvider: Sendable {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent>
}
