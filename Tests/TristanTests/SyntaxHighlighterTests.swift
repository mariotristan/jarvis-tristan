import XCTest
@testable import Tristan

final class SyntaxHighlighterTests: XCTestCase {
    private func tokens(_ code: String, _ language: String) -> [SyntaxToken] { SyntaxHighlighter.tokenize(code, language: language) }
    private func kinds(_ code: String, _ language: String, of kind: SyntaxKind) -> [String] {
        tokens(code, language).filter { $0.kind == kind }.map(\.text)
    }

    func testTokensAlwaysRebuildTheOriginalText() {
        let samples = [
            "let x = \"hi\" // note\nfunc f() -> Int { 42 }",
            "{\"a\": [1, 2.5, true, null], \"b\": \"c\"}",
            "name: demo\n# comment\nitems:\n  - one: 1",
            "echo \"$HOME\" # hi\nif [ -f a ]; then ls; fi",
            "def f(x):\n    return x  # done",
            "const s = `a ${b}`; /* c */ let n = 0x1F",
            "",
            "\n\n  \t",
            "emoji 😀 \"naïve\" é",
        ]
        for language in ["swift", "typescript", "javascript", "python", "shell", "json", "yaml", "text", ""] {
            for code in samples {
                XCTAssertEqual(tokens(code, language).map(\.text).joined(), code, "\(language): \(code)")
            }
        }
    }

    func testSwiftKeywordsStringsCommentsAndNumbers() {
        let code = "let total = 42 + 3.5 // sum\nvar name = \"Ada\"\nfunc go() {}"
        XCTAssertEqual(kinds(code, "swift", of: .keyword), ["let", "var", "func"])
        XCTAssertEqual(kinds(code, "swift", of: .number), ["42", "3.5"])
        XCTAssertEqual(kinds(code, "swift", of: .string), ["\"Ada\""])
        XCTAssertEqual(kinds(code, "swift", of: .comment), ["// sum"])
    }

    func testKeywordsInsideWordsAreNotKeywords() {
        XCTAssertEqual(kinds("letter = iffy + classic", "swift", of: .keyword), [])
        XCTAssertEqual(kinds("x1 = 2", "swift", of: .number), ["2"], "digits inside an identifier are not numbers")
    }

    func testKeywordsInsideStringsAndCommentsStayPlainText() {
        XCTAssertEqual(kinds("\"let it be\" // func", "swift", of: .keyword), [])
    }

    func testUnfinishedStringAndCommentAreStillColoured() {
        XCTAssertEqual(kinds("let s = \"half a str", "swift", of: .string), ["\"half a str"])
        XCTAssertEqual(kinds("x /* still open\nlet", "swift", of: .comment), ["/* still open\nlet"])
    }

    func testAStringDoesNotRunPastItsLineWithEscapes() {
        XCTAssertEqual(kinds("a = \"say \\\"hi\\\"\" + b", "swift", of: .string), ["\"say \\\"hi\\\"\""])
        XCTAssertEqual(kinds("a = \"open\nlet b = 1", "swift", of: .string), ["\"open"], "a plain string ends at the line break")
    }

    func testTypeScriptAndJavaScriptShareRules() {
        let code = "const n: number = 1; // one\nexport function f() { return `t` }"
        for language in ["typescript", "ts", "tsx", "javascript", "js", "jsx"] {
            XCTAssertEqual(kinds(code, language, of: .keyword), ["const", "export", "function", "return"], language)
            XCTAssertEqual(kinds(code, language, of: .string), ["`t`"], language)
            XCTAssertEqual(kinds(code, language, of: .comment), ["// one"], language)
        }
    }

    func testPythonUsesHashCommentsAndTripleQuotes() {
        let code = "def f(x):\n    \"\"\"doc\n    more\"\"\"\n    return x  # done"
        XCTAssertEqual(kinds(code, "python", of: .keyword), ["def", "return"])
        XCTAssertEqual(kinds(code, "py", of: .string), ["\"\"\"doc\n    more\"\"\""])
        XCTAssertEqual(kinds(code, "python", of: .comment), ["# done"])
    }

    func testShellComments() {
        let code = "#!/bin/bash\nif [ -f a ]; then echo \"ok\" # fine\nfi"
        for language in ["shell", "sh", "bash", "zsh"] {
            XCTAssertEqual(kinds(code, language, of: .keyword), ["if", "then", "fi"], language)
            XCTAssertEqual(kinds(code, language, of: .comment), ["#!/bin/bash", "# fine"], language)
            XCTAssertEqual(kinds(code, language, of: .string), ["\"ok\""], language)
        }
        XCTAssertEqual(kinds("echo a#b", "shell", of: .comment), [], "a hash inside a word is not a comment")
    }

    func testJSONKeysAreToldApartFromValues() {
        let code = "{\"name\": \"Ada\", \"age\": 36, \"ok\": true, \"x\": null}"
        XCTAssertEqual(kinds(code, "json", of: .key), ["\"name\"", "\"age\"", "\"ok\"", "\"x\""])
        XCTAssertEqual(kinds(code, "json", of: .string), ["\"Ada\""])
        XCTAssertEqual(kinds(code, "json", of: .number), ["36"])
        XCTAssertEqual(kinds(code, "json", of: .keyword), ["true", "null"])
    }

    func testYAMLKeysCommentsAndValues() {
        let code = "name: demo # trailing\nitems:\n  - count: 3\n  - \"quoted\": yes"
        for language in ["yaml", "yml"] {
            XCTAssertEqual(kinds(code, language, of: .key), ["name", "items", "count", "\"quoted\""], language)
            XCTAssertEqual(kinds(code, language, of: .comment), ["# trailing"], language)
            XCTAssertEqual(kinds(code, language, of: .number), ["3"], language)
        }
        XCTAssertEqual(kinds("url: http://a.b/c", "yaml", of: .key), ["url"], "a colon inside a value does not start another key")
    }

    func testLanguageNamesAreCaseInsensitiveAndUnknownOnesStayPlain() {
        XCTAssertEqual(kinds("let a = 1", "Swift", of: .keyword), ["let"])
        for language in ["", "text", "rust", "diff"] {
            XCTAssertEqual(tokens("let a = \"b\" // c", language), [SyntaxToken(kind: .plain, text: "let a = \"b\" // c")], language)
        }
        XCTAssertEqual(tokens("", "swift"), [])
    }

    func testEveryPrefixOfStreamedTextTokenizesWithoutLosingText() {
        let code = "func f() {\n  let s = \"a\\\"b\" /* c */ // d\n  return 0x1F\n}\n\"\"\"x"
        for language in ["swift", "python", "json", "yaml", "shell"] {
            for end in code.indices {
                let prefix = String(code[...end])
                XCTAssertEqual(tokens(prefix, language).map(\.text).joined(), prefix, "\(language) at \(prefix.count)")
            }
        }
    }
}
