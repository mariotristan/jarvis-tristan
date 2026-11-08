import Foundation

// A small, dependency-free highlighter for the code cards. It is a hand-written scanner, not a parser: it only has to
// colour what an agent writes, and it must cope with text that is still streaming in (an unfinished string or comment
// is simply coloured to the end). The tokens always rebuild the original text exactly.

enum SyntaxKind: Equatable {
    case plain, keyword, string, comment, number, key
}

struct SyntaxToken: Equatable {
    var kind: SyntaxKind
    var text: String
}

enum SyntaxHighlighter {
    private struct Rules {
        var keywords: Set<String> = []
        var lineComments: [String] = []
        var blockComments = false
        var quotes: [Character] = []
        var multilineQuotes: [Character] = []   // a string that may run over several lines (template literals)
        var tripleQuotes = false
        var jsonKeys = false
        var yaml = false
    }

    private static let swift = Rules(
        keywords: ["import", "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "if", "else", "guard", "switch", "case",
                   "default", "for", "while", "repeat", "return", "break", "continue", "in", "is", "as", "try", "catch", "throw", "throws",
                   "async", "await", "actor", "init", "self", "super", "nil", "true", "false", "static", "private", "public", "internal",
                   "fileprivate", "open", "override", "final", "where", "some", "any", "typealias", "defer", "do"],
        lineComments: ["//"], blockComments: true, quotes: ["\""], tripleQuotes: true)

    private static let script = Rules(
        keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "class", "extends", "new", "import", "export",
                   "from", "default", "async", "await", "try", "catch", "throw", "typeof", "interface", "type", "enum", "implements",
                   "public", "private", "readonly", "static", "switch", "case", "break", "continue", "this", "null", "undefined", "true",
                   "false", "of", "in", "as"],
        lineComments: ["//"], blockComments: true, quotes: ["\"", "'", "`"], multilineQuotes: ["`"])

    private static let python = Rules(
        keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as",
                   "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "None", "True", "False",
                   "async", "await", "global", "nonlocal", "del", "assert"],
        lineComments: ["#"], quotes: ["\"", "'"], tripleQuotes: true)

    private static let shell = Rules(
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return",
                   "exit", "export", "local"],
        lineComments: ["#"], quotes: ["\"", "'"])

    private static let json = Rules(keywords: ["true", "false", "null"], quotes: ["\""], jsonKeys: true)

    private static let yaml = Rules(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], quotes: ["\"", "'"], yaml: true)

    private static func rules(for language: String) -> Rules? {
        switch language.lowercased() {
        case "swift": return swift
        case "typescript", "ts", "tsx", "javascript", "js", "jsx", "mjs": return script
        case "python", "py": return python
        case "shell", "sh", "bash", "zsh": return shell
        case "json", "jsonc": return json
        case "yaml", "yml": return yaml
        default: return nil
        }
    }

    static func tokenize(_ code: String, language: String) -> [SyntaxToken] {
        guard !code.isEmpty else { return [] }
        guard let rules = rules(for: language) else { return [SyntaxToken(kind: .plain, text: code)] }
        var tokens: [SyntaxToken] = []
        if rules.yaml {
            for line in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.offset > 0 { tokens.append(SyntaxToken(kind: .plain, text: "\n")) }
                let text = Array(line.element)
                let keyEnd = yamlKeyRange(text)
                if let keyEnd {
                    tokens.append(SyntaxToken(kind: .plain, text: String(text[..<keyEnd.lowerBound])))
                    tokens.append(SyntaxToken(kind: .key, text: String(text[keyEnd])))
                    scan(Array(text[keyEnd.upperBound...]), rules, into: &tokens)
                } else {
                    scan(text, rules, into: &tokens)
                }
            }
        } else {
            scan(Array(code), rules, into: &tokens)
        }
        return merged(tokens)
    }

    /// The range of a YAML key at the start of a line (after indentation and a list dash), if the line has one.
    private static func yamlKeyRange(_ line: [Character]) -> Range<Int>? {
        var start = 0
        while start < line.count, line[start] == " " || line[start] == "\t" { start += 1 }
        while start + 1 < line.count, line[start] == "-", line[start + 1] == " " {
            start += 2
            while start < line.count, line[start] == " " { start += 1 }
        }
        guard start < line.count, line[start] != "#" else { return nil }
        var i = start
        if line[i] == "\"" || line[i] == "'" {
            let quote = line[i]
            i += 1
            while i < line.count, line[i] != quote { i += line[i] == "\\" ? 2 : 1 }
            guard i < line.count else { return nil }
            i += 1
            guard i < line.count, line[i] == ":" else { return nil }
            return start..<i
        }
        while i < line.count {
            if line[i] == ":" , i + 1 == line.count || line[i + 1] == " " { return i > start ? start..<i : nil }
            if line[i] == "#", i > start, line[i - 1] == " " { return nil }
            i += 1
        }
        return nil
    }

    private static func scan(_ chars: [Character], _ rules: Rules, into tokens: inout [SyntaxToken]) {
        var i = 0
        func hasPrefix(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix)
            guard index + p.count <= chars.count else { return false }
            return Array(chars[index..<index + p.count]) == p
        }
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func add(_ kind: SyntaxKind, _ from: Int, _ to: Int) { tokens.append(SyntaxToken(kind: kind, text: String(chars[from..<to]))) }

        while i < chars.count {
            let c = chars[i]
            // Comments: a hash only counts at the start of a line or after a space, so `a#b` stays plain.
            if rules.blockComments, hasPrefix("/*", at: i) {
                var j = i + 2
                while j < chars.count, !hasPrefix("*/", at: j) { j += 1 }
                j = min(chars.count, j + 2)
                add(.comment, i, j); i = j; continue
            }
            if let marker = rules.lineComments.first(where: { hasPrefix($0, at: i) }),
               marker != "#" || i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" || chars[i - 1] == "\n" {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                add(.comment, i, j); i = j; continue
            }
            if rules.tripleQuotes, c == "\"" || c == "'", hasPrefix(String(repeating: c, count: 3), at: i) {
                let closing = String(repeating: c, count: 3)
                var j = i + 3
                while j < chars.count, !hasPrefix(closing, at: j) { j += chars[j] == "\\" ? 2 : 1 }
                j = min(chars.count, j + 3)
                add(.string, i, j); i = j; continue
            }
            if rules.quotes.contains(c) {
                let multiline = rules.multilineQuotes.contains(c)
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == "\\" { j = min(chars.count, j + 2); continue }
                    if chars[j] == c { j += 1; closed = true; break }
                    if chars[j] == "\n", !multiline { break }
                    j += 1
                }
                var kind = SyntaxKind.string
                if rules.jsonKeys, closed {
                    var k = j
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    if k < chars.count, chars[k] == ":" { kind = .key }
                }
                add(kind, i, j); i = j; continue
            }
            if c.isNumber, i == 0 || !isWordChar(chars[i - 1]) {
                var j = i + 1
                if c == "0", j < chars.count, chars[j] == "x" || chars[j] == "X" {
                    j += 1
                    while j < chars.count, chars[j].isHexDigit { j += 1 }
                } else {
                    while j < chars.count, chars[j].isNumber || chars[j] == "_" || (chars[j] == "." && j + 1 < chars.count && chars[j + 1].isNumber) { j += 1 }
                }
                add(.number, i, j); i = j; continue
            }
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count, isWordChar(chars[j]) { j += 1 }
                add(rules.keywords.contains(String(chars[i..<j])) ? .keyword : .plain, i, j); i = j; continue
            }
            add(.plain, i, i + 1); i += 1
        }
    }

    private static func merged(_ tokens: [SyntaxToken]) -> [SyntaxToken] {
        var result: [SyntaxToken] = []
        for token in tokens where !token.text.isEmpty {
            if token.kind == .plain, let last = result.last, last.kind == .plain {
                result[result.count - 1].text += token.text
            } else {
                result.append(token)
            }
        }
        return result
    }
}
