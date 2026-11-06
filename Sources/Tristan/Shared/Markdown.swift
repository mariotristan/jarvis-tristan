import SwiftUI

// A small markdown engine for the code stream: a block parser that can be unit-tested, plus SwiftUI views.
// It deliberately renders only what an agent produces (headings, lists, quotes, tables, fenced code, inline styles).

enum MarkdownBlock: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    struct Item: Equatable {
        var depth: Int
        var marker: String          // "•" or "1."
        var text: String
        var checked: Bool?          // task list items
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, title: String?, content: String, closed: Bool)
    case list([Item])
    case quote(String)
    case table(header: [String], rows: [[String]], alignments: [Alignment])
    case rule
}

enum MarkdownParser {
    private struct Fence { var char: Character; var length: Int; var language: String; var title: String? }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }

            if let fence = openingFence(line) {
                flush(); i += 1
                var content: [String] = []
                var closed = false
                while i < lines.count {
                    if isClosingFence(lines[i], for: fence) { closed = true; i += 1; break }
                    content.append(lines[i]); i += 1
                }
                blocks.append(.code(language: fence.language, title: fence.title, content: content.joined(separator: "\n"), closed: closed))
                continue
            }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); i += 1; continue }
            if isRule(trimmed) { flush(); blocks.append(.rule); i += 1; continue }
            if i + 1 < lines.count, trimmed.contains("|"), isTableDelimiter(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                let alignments = cells(lines[i + 1]).map(alignment)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].contains("|") {
                    var row = cells(lines[i])
                    while row.count < header.count { row.append("") }
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var body = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quoted.append(body); i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if listItem(line) != nil {
                flush()
                var items: [MarkdownBlock.Item] = []
                var indents: [Int] = []
                let startsOrdered = listItem(line)?.marker != "•"
                while i < lines.count {
                    let current = lines[i]
                    if let (indent, marker, body) = listItem(current) {
                        while let last = indents.last, indent < last { indents.removeLast() }
                        if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
                        // Switching between bullets and numbers at the top level starts a new list.
                        if indents.count == 1, !items.isEmpty, (marker != "•") != startsOrdered { break }
                        var text = body
                        var checked: Bool?
                        if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
                        else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
                        items.append(MarkdownBlock.Item(depth: indents.count - 1, marker: marker, text: text, checked: checked))
                        i += 1
                    } else if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line continues the list only if the next non-blank line is another item.
                        var j = i + 1
                        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                        if j < lines.count, listItem(lines[j]) != nil { i = j } else { break }
                    } else if current.hasPrefix("  ") || current.hasPrefix("\t"), !items.isEmpty, openingFence(current) == nil {
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    // MARK: pieces

    private static func openingFence(_ line: String) -> Fence? {
        guard let regex = try? NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})\s*(.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let marker = Range(match.range(at: 1), in: line), let info = Range(match.range(at: 2), in: line) else { return nil }
        let fenceText = String(line[marker])
        let infoText = String(line[info]).trimmingCharacters(in: .whitespaces)
        if fenceText.hasPrefix("`"), infoText.contains("`") { return nil }     // that is inline code, not a fence
        var language = infoText
        var title: String?
        if let range = infoText.range(of: "title=") {
            language = String(infoText[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            title = String(infoText[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if title?.isEmpty == true { title = nil }
        }
        language = language.split(separator: " ").first.map(String.init) ?? ""
        return Fence(char: fenceText.first!, length: fenceText.count, language: language, title: title)
    }

    private static func isClosingFence(_ line: String, for fence: Fence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard line.prefix(while: { $0 == " " }).count <= 3, trimmed.count >= fence.length else { return false }
        return trimmed.allSatisfy { $0 == fence.char }
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        return marks.count >= 3 && Set(marks).count == 1 && "-*_".contains(marks.first!)
    }

    private static func listItem(_ line: String) -> (indent: Int, marker: String, body: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let lead = Range(match.range(at: 1), in: line), let mark = Range(match.range(at: 2), in: line),
              let body = Range(match.range(at: 3), in: line) else { return nil }
        let indent = line[lead].reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let raw = String(line[mark])
        let marker = raw.first!.isNumber ? String(raw.dropLast()) + "." : "•"
        return (indent, marker, String(line[body]))
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else { return false }
        let parts = cells(trimmed)
        return !parts.isEmpty && parts.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 1 && core.allSatisfy { $0 == "-" } && cell.count >= 1
        }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func alignment(_ cell: String) -> MarkdownBlock.Alignment {
        let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
        return left && right ? .center : right ? .trailing : .leading
    }
}

/// Builds the fenced blocks that carry file contents through the code stream, so the whole stream is valid markdown.
enum CodeFence {
    static func block(path: String, content: String) -> String {
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

    static func isMarkdown(_ language: String) -> Bool { ["markdown", "md"].contains(language.lowercased()) }
}

// MARK: inline text

enum MarkdownInline {
    /// Links are limited to web and mail addresses. Model output must never be able to plant a `tristan://` pairing
    /// link or a `file://` link that a tap would follow.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func attributed(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
        let runs = result.runs.map { ($0.range, $0.link, $0.inlinePresentationIntent) }
        for (range, link, intent) in runs {
            if let link, !allowedSchemes.contains(link.scheme?.lowercased() ?? "") { result[range].link = nil }
            if intent?.contains(.code) == true {
                result[range].foregroundColor = Theme.amber
                result[range].backgroundColor = Theme.inlineCode
            }
            if link != nil, allowedSchemes.contains(link?.scheme?.lowercased() ?? "") { result[range].foregroundColor = Theme.cyan }
        }
        return result
    }
}

// MARK: views

private struct HudScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// 1 normally; larger in full-screen mode so text stays readable on a big display.
    var hudScale: CGFloat {
        get { self[HudScaleKey.self] }
        set { self[HudScaleKey.self] = newValue }
    }
}

struct MarkdownView: View {
    let text: String
    @Environment(\.hudScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private var proseColor: Color { Theme.prose }

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.hudScale) private var scale

    var body: some View {
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = [22, 19, 17, 15, 14, 13]
            Text(MarkdownInline.attributed(text))
                .font(.system(size: sizes[level - 1] * scale, weight: .bold))
                .foregroundStyle(level <= 2 ? Theme.cyan : Theme.amber)
                .shadow(color: level <= 2 ? Theme.cyan.opacity(0.5) : .clear, radius: 4)
                .padding(.top, level <= 2 ? 4 * scale : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .font(.system(size: 13.5 * scale)).foregroundStyle(proseColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4 * scale) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(Theme.green)
                        } else {
                            Text(item.marker).foregroundStyle(Theme.amber)
                        }
                        Text(MarkdownInline.attributed(item.text)).foregroundStyle(proseColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 13.5 * scale))
                    .padding(.leading, CGFloat(item.depth) * 18 * scale)
                }
            }
            .textSelection(.enabled)
        case .quote(let text):
            HStack(alignment: .top, spacing: 9 * scale) {
                Rectangle().fill(Theme.amber.opacity(0.8)).frame(width: 3 * scale)
                Text(MarkdownInline.attributed(text)).font(.system(size: 13.5 * scale)).foregroundStyle(proseColor.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        case .rule:
            Rectangle().fill(Theme.cyan.opacity(0.35)).frame(height: 1).padding(.vertical, 4 * scale)
        case .table(let header, let rows, let alignments):
            MarkdownTable(header: header, rows: rows, alignments: alignments)
        case .code(let language, let title, let content, let closed):
            CodeCard(language: language, title: title, content: content, closed: closed)
        }
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [MarkdownBlock.Alignment]
    @Environment(\.hudScale) private var scale

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                        cell(text, header: true, column: column)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cell(text, header: false, column: column)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.4), lineWidth: 1))
        }
    }

    private func cell(_ text: String, header: Bool, column: Int) -> some View {
        Text(MarkdownInline.attributed(text))
            .font(.system(size: 12.5 * scale, weight: header ? .bold : .regular))
            .foregroundStyle(header ? Theme.amber : proseColor)
            .multilineTextAlignment(textAlignment(column))
            .padding(.horizontal, 10 * scale).padding(.vertical, 6 * scale)
            .frame(minWidth: 60 * scale, maxWidth: .infinity, alignment: Alignment(horizontal: alignment(column), vertical: .center))
            .background(header ? Theme.cyan.opacity(0.14) : Color.clear)
            .overlay(Rectangle().stroke(Theme.cyan.opacity(0.18), lineWidth: 0.5))
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
}

/// A fenced block: a header with the language and file name, a copy button, and the code. A markdown file is shown
/// rendered, with a switch to see its source.
struct CodeCard: View {
    let language: String
    let title: String?
    let content: String
    let closed: Bool
    @State private var showSource = false
    @State private var copied = false
    @Environment(\.hudScale) private var scale

    private var isMarkdown: Bool { CodeFence.isMarkdown(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((title ?? (language.isEmpty ? "code" : language)).uppercased())
                    .font(.system(size: 10 * scale, weight: .bold, design: .monospaced)).tracking(1)
                    .foregroundStyle(Theme.amber).lineLimit(1).truncationMode(.middle)
                if title != nil, !language.isEmpty {
                    Text(language).font(.system(size: 9 * scale, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.6))
                        .padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.cyan.opacity(0.35), lineWidth: 1))
                }
                if !closed { Text("writing…").font(.system(size: 9 * scale, design: .monospaced)).foregroundStyle(Theme.green.opacity(0.7)) }
                Spacer(minLength: 4)
                if isMarkdown {
                    Button { showSource.toggle() } label: {
                        Text(showSource ? "RENDERED" : "SOURCE").font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.cyan)
                    }
                    .buttonStyle(.hud)
                }
                Button { copy() } label: {
                    Text(copied ? "COPIED" : "COPY").font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
                        .foregroundStyle(copied ? Theme.green : Theme.cyan)
                }
                .buttonStyle(.hud)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.cyan.opacity(0.10))

            Group {
                if isMarkdown && !showSource {
                    MarkdownView(text: content)
                } else {
                    Text(content.isEmpty ? " " : content)
                        .font(.system(size: 12 * scale, design: .monospaced)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
        }
        .background(Theme.codeWash, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.green.opacity(0.35), lineWidth: 1))
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        #else
        UIPasteboard.general.string = content
        #endif
        copied = true
    }
}

/// What the code stream shows: rendered markdown, or the raw text.
struct RenderedStream: View {
    let text: String
    let rendered: Bool
    var placeholder = "Awaiting orders, sir."
    @Environment(\.hudScale) private var scale

    var body: some View {
        if text.isEmpty {
            Text(placeholder).font(.system(size: 12 * scale, design: .monospaced)).foregroundStyle(Theme.cyan.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if rendered {
            MarkdownView(text: text)
        } else {
            Text(text).font(.system(size: 12 * scale, design: .monospaced)).foregroundStyle(Theme.green)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
