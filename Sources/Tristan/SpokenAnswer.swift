import Foundation

/// Decides whether a finished task's answer is short enough to be read aloud. A short plain answer ("The biggest
/// planet is Jupiter.") is worth hearing; code, lists and long text stay on screen and get the usual confirmation.
enum SpokenAnswer {
    static let maxCharacters = 200
    static let maxLines = 3

    /// The text to speak, or nil when the answer is empty, long, or holds code.
    static func line(for summary: String) -> String? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxCharacters, !text.contains("`") else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count <= maxLines else { return nil }
        return text
    }
}
