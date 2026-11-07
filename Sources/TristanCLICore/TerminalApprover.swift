import Foundation
import TristanCore

/// Answers approval requests in the terminal. Without a terminal (stdin is not a TTY) every request is denied, so an
/// unattended `ask` run can never do something nobody approved; `--yes-routine` and `--yolo` must be chosen explicitly.
final class TerminalApprover: @unchecked Sendable {
    private let interactive: Bool
    private let mode: ApprovalMode
    private let input: () -> String?
    private let output: (String) -> Void
    /// One prompt at a time: providers may ask from several tasks.
    private let lock = NSLock()
    private(set) var denials = 0

    /// `input` returns one line typed by the user (nil at end of input); `output` shows prompt text (stderr).
    init(interactive: Bool, mode: ApprovalMode, input: @escaping () -> String?, output: @escaping (String) -> Void) {
        self.interactive = interactive
        self.mode = mode
        self.input = input
        self.output = output
    }

    func approve(_ request: ApprovalRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // YOLO was asked for explicitly with --yolo; providers in that mode normally do not ask at all.
        if mode == .yolo { return true }
        if let rule = request.rule, Self.storedRules().contains(where: { $0.key == rule.key }) {
            output("Allowed by saved rule: \(rule.label) (\(request.summary) \(request.detail))\n")
            return true
        }
        guard interactive else {
            output("Denied (no terminal to ask in): \(request.summary) \(request.detail)\n"
                   + "  Run in a terminal to answer, or pass --yes-routine or --yolo to run unattended.\n")
            denials += 1
            return false
        }
        output("\n\(request.summary)\n  \(request.detail)\n")
        if let rule = request.rule { output("  always allows: \(rule.label)\n") }
        output("[y]es / [n]o / [a]lways: ")
        let answer = (input() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch answer.lowercased() {
        case "y", "yes":
            output("Allowed\n")
            return true
        case "a", "always":
            if let rule = request.rule {
                Self.store(rule)
                output("Allowed, and always from now on: \(rule.label)\n")
            } else {
                output("Allowed (this action cannot be allowed always)\n")
            }
            return true
        default:
            output("Denied\n")
            denials += 1
            return false
        }
    }

    /// The same `allowRules` value the Mac app keeps: JSON data of `[ApprovalRule]`.
    static func storedRules() -> [ApprovalRule] {
        guard let data = Settings.data("allowRules"),
              let rules = try? JSONDecoder().decode([ApprovalRule].self, from: data) else { return [] }
        return rules
    }

    static func store(_ rule: ApprovalRule) {
        var rules = storedRules()
        guard !rules.contains(where: { $0.key == rule.key }) else { return }
        rules.append(rule)
        if let data = try? JSONEncoder().encode(rules) { Settings.set(data, forKey: "allowRules") }
    }
}
