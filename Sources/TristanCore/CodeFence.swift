import Foundation

/// Builds the fenced blocks that carry file contents through the code stream, so the whole stream is valid markdown.
package enum CodeFence {
    package static func block(path: String, content: String) -> String {
        var longest = 0, run = 0
        for character in content { if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: max(3, longest + 1))      // longer than any fence inside the file
        let body = content.hasSuffix("\n") ? String(content.dropLast()) : content
        // A model-chosen path must never be able to end the header line (or the fence) early.
        // (Backticks too: a backtick in the header line would make it look like inline code instead of a fence.)
        let title = path.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 == "`" ? "'" : String($0) }.joined()
        return "\n\(fence)\(language(forPath: title)) title=\(title)\n\(body)\n\(fence)\n"
    }

    static func language(forPath path: String) -> String {
        let ext = String((path as NSString).pathExtension.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let names = ["md": "markdown", "markdown": "markdown", "ts": "typescript", "tsx": "tsx", "js": "javascript", "jsx": "jsx",
                     "py": "python", "rb": "ruby", "rs": "rust", "kt": "kotlin", "yml": "yaml", "sh": "bash", "zsh": "bash"]
        return names[ext] ?? (ext.isEmpty ? "text" : ext)
    }

    package static func isMarkdown(_ language: String) -> Bool { ["markdown", "md"].contains(language.lowercased()) }
}
