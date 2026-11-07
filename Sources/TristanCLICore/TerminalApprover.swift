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
        // Everything shown comes from the model or the tool: control characters are made visible so the text
        // cannot rewrite the prompt (for example a carriage return and an erase-line hiding the real command).
        let summary = Self.visible(request.summary), detail = Self.visible(request.detail)
        let label = request.rule.map { Self.visible($0.label) }
        // With no terminal, saved rules approve nothing: an unattended run never acts without a person present.
        guard interactive else {
            output("Denied (no terminal to ask in): \(summary) \(detail)\n"
                   + "  Run in a terminal to answer, or pass --yes-routine or --yolo to run unattended.\n")
            denials += 1
            return false
        }
        if let rule = request.rule, let label, Self.storedRules().contains(where: { $0.key == rule.key }) {
            output("Allowed by saved rule: \(label) (\(summary) \(detail))\n")
            return true
        }
        output("\n\(summary)\n  \(detail)\n")
        if let label { output("  always allows: \(label)\n") }
        output("[y]es / [n]o / [a]lways: ")
        let answer = (input() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch answer.lowercased() {
        case "y", "yes":
            output("Allowed\n")
            return true
        case "a", "always":
            if let rule = request.rule, let label {
                Self.store(rule)
                output("Allowed, and always from now on: \(label)\n")
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

    /// `text` with every character a terminal would act on shown as an escape instead: C0 controls except the line
    /// break (`\e`, `\r`, `\b`, `\t`, else `\xNN`), DEL, C1 controls (`\xNN`) and the bidi overrides and isolates
    /// (`\u{202E}`). Ordinary text, line breaks and non-ASCII letters are unchanged.
    static func visible(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: result.unicodeScalars.append(scalar)
            case 0x1B: result += "\\e"
            case 0x0D: result += "\\r"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x00...0x1F, 0x7F, 0x80...0x9F: result += String(format: "\\x%02X", scalar.value)
            case 0x202A...0x202E, 0x2066...0x2069: result += String(format: "\\u{%04X}", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
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
