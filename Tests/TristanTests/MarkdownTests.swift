import XCTest
import AppKit
import SwiftUI
@testable import Tristan
@testable import TristanCore

final class MarkdownParserTests: XCTestCase {
    private func parse(_ text: String) -> [MarkdownBlock] { MarkdownParser.parse(text) }

    func testHeadings() {
        XCTAssertEqual(parse("# Title\n## Sub ##\n###### Tiny"), [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .heading(level: 6, text: "Tiny")])
        XCTAssertEqual(parse("#hashtag"), [.paragraph("#hashtag")], "needs a space after the hashes")
        XCTAssertEqual(parse("####### seven"), [.paragraph("####### seven")])
    }

    func testParagraphsKeepLineBreaksAndSplitOnBlankLines() {
        XCTAssertEqual(parse("one\ntwo\n\nthree"), [.paragraph("one\ntwo"), .paragraph("three")])
    }

    func testListsNestingOrderingAndTasks() {
        let blocks = parse("- a\n  - b\n    - c\n- d\n\n1. first\n2. second\n\n- [ ] todo\n- [x] done")
        guard case .list(let bullets) = blocks[0] else { return XCTFail("expected a list") }
        XCTAssertEqual(bullets.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(bullets.map(\.text), ["a", "b", "c", "d"])
        guard case .list(let numbered) = blocks[1] else { return XCTFail("expected a numbered list") }
        XCTAssertEqual(numbered.map(\.marker), ["1.", "2."])
        guard case .list(let tasks) = blocks[2] else { return XCTFail("expected a task list") }
        XCTAssertEqual(tasks.map(\.checked), [false, true])
        XCTAssertEqual(tasks.map(\.text), ["todo", "done"])
    }

    func testNestingWorksWithFourSpaceIndents() {
        guard case .list(let items) = parse("- a\n    - b\n        - c")[0] else { return XCTFail() }
        XCTAssertEqual(items.map(\.depth), [0, 1, 2])
    }

    func testListContinuationAndLooseLists() {
        guard case .list(let items) = parse("- one\n  continues here\n\n- two")[0] else { return XCTFail() }
        XCTAssertEqual(items.map(\.text), ["one\ncontinues here", "two"])
    }

    func testFencedCodeCarriesLanguageAndTitle() {
        XCTAssertEqual(parse("```swift title=Sources/App.swift\nlet x = 1\n```"),
                       [.code(language: "swift", title: "Sources/App.swift", content: "let x = 1", closed: true)])
        XCTAssertEqual(parse("```\nplain\n```"), [.code(language: "", title: nil, content: "plain", closed: true)])
        XCTAssertEqual(parse("~~~python\nprint(1)\n~~~"), [.code(language: "python", title: nil, content: "print(1)", closed: true)])
        XCTAssertEqual(parse("```text title=My Folder/a file.txt\nx\n```"),
                       [.code(language: "text", title: "My Folder/a file.txt", content: "x", closed: true)], "paths with spaces survive")
    }

    func testAnUnfinishedFenceWhileStreamingIsShownAsOpen() {
        XCTAssertEqual(parse("Intro\n```ts title=a.ts\nconst x ="), [.paragraph("Intro"), .code(language: "ts", title: "a.ts", content: "const x =", closed: false)])
    }

    func testALongerFenceCanContainShorterOnes() {
        let blocks = parse("````markdown title=README.md\n# Hi\n```bash\nls\n```\n````\nafter")
        XCTAssertEqual(blocks, [.code(language: "markdown", title: "README.md", content: "# Hi\n```bash\nls\n```", closed: true), .paragraph("after")])
    }

    func testInlineTripleBackticksAreNotAFence() {
        XCTAssertEqual(parse("```inline``` text"), [.paragraph("```inline``` text")])
    }

    func testTablesWithAlignmentAndShortRows() {
        let blocks = parse("| Name | Qty | Note |\n|:-----|----:|:----:|\n| a | 1 | x |\n| b | 2 |")
        XCTAssertEqual(blocks, [.table(header: ["Name", "Qty", "Note"], rows: [["a", "1", "x"], ["b", "2", ""]], alignments: [.leading, .trailing, .center])])
    }

    func testQuotesAndRules() {
        XCTAssertEqual(parse("> one\n> two"), [.quote("one\ntwo")])
        for rule in ["---", "***", "___", "- - -", "* * *"] { XCTAssertEqual(parse(rule), [.rule], "\(rule) is a rule") }
    }

    func testAMixedDocumentKeepsItsOrder() {
        let doc = "# Plan\n\nSome **bold** text.\n\n- step one\n- step two\n\n```swift title=a.swift\nlet a = 1\n```\n\nDone."
        let kinds = parse(doc).map { block -> String in
            switch block { case .heading: return "h"; case .paragraph: return "p"; case .list: return "l"; case .code: return "c"; default: return "?" }
        }
        XCTAssertEqual(kinds.joined(), "hplcp")
    }

    // MARK: robustness

    func testEveryPrefixOfADocumentParsesWithoutCrashing() {
        let doc = "# T\n- a\n  - b\n\n| h | i |\n|---|--:|\n| 1 | 2 |\n\n````md\n```x\n```\n````\n> q\n---\n`code` and **bold** [l](https://a.b)\n"
        for end in doc.indices { _ = MarkdownParser.parse(String(doc[..<end])) }       // exactly what streaming does
        XCTAssertFalse(MarkdownParser.parse(doc).isEmpty)
    }

    func testRandomMarkdownFragmentsNeverCrash() {
        let pieces = ["#", "## ", "- ", "1. ", "* ", "> ", "```", "~~~", "````", "|", "---", ":--", "\n", "\n\n", " ", "  ", "\t", "[x]", "[ ] ",
                      "`", "**", "_", "title=", "swift", "é", "🙂", "\\", "<", "&", "0", "text"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let text = (0..<Int.random(in: 1...60, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            _ = MarkdownParser.parse(text)
        }
    }
}

/// CodeFence blocks through the Markdown parser; the parser-free CodeFence tests are in TristanCoreTests.
final class CodeFenceMarkdownTests: XCTestCase {
    func testAFenceBlockRoundTripsThroughTheParserForAwkwardContent() {
        let samples = ["let x = 1", "", "line\n\nafter a blank", "has ``` three ticks\ninside", "````four````", "~~~ tildes ~~~", "trailing space  \n  indented",
                       "# heading inside\n- list inside", "unicode é 🙂", "last line has no newline"]
        for content in samples {
            let blocks = MarkdownParser.parse(CodeFence.block(path: "dir/file.txt", content: content))
            XCTAssertEqual(blocks, [.code(language: "txt", title: "dir/file.txt", content: content, closed: true)], "content: \(content.debugDescription)")
        }
    }

    func testATrailingNewlineIsNotDuplicated() {
        XCTAssertEqual(MarkdownParser.parse(CodeFence.block(path: "a.txt", content: "x\n")),
                       [.code(language: "txt", title: "a.txt", content: "x", closed: true)])
    }

    func testAHostilePathCannotBreakOutOfTheFenceHeader() {
        let block = CodeFence.block(path: "evil.txt\n```\n# injected heading", content: "body")
        let blocks = MarkdownParser.parse(block)
        XCTAssertEqual(blocks.count, 1, "a newline in the path must not end the fence early")
        guard case .code(_, _, let content, true) = blocks[0] else { return XCTFail("expected one closed code block") }
        XCTAssertEqual(content, "body")
    }

    func testStreamedFileContentArrivesInsideOneBlock() {
        let prose = "Creating the file:\n"
        let stream = prose + CodeFence.block(path: "a.md", content: "# Title\n\n- item")
        let kinds = MarkdownParser.parse(stream)
        XCTAssertEqual(kinds.count, 2)
        guard case .code(let language, _, let content, _) = kinds[1] else { return XCTFail() }
        XCTAssertTrue(CodeFence.isMarkdown(language))
        XCTAssertEqual(content, "# Title\n\n- item", "a written .md file is a markdown block that the card renders")
    }
}

final class MarkdownInlineTests: XCTestCase {
    private func links(_ text: String) -> [URL] { MarkdownInline.attributed(text).runs.compactMap(\.link) }

    func testOnlyWebAndMailLinksSurvive() {
        XCTAssertEqual(links("[a](https://example.com/x)").map(\.absoluteString), ["https://example.com/x"])
        XCTAssertEqual(links("[a](mailto:me@example.com)").count, 1)
        for hostile in ["[pair](tristan://pair?host=evil&port=1&secret=00)", "[f](file:///etc/passwd)", "[j](javascript:alert(1))",
                        "[d](data:text/html;base64,AAAA)", "[s](ssh://root@host)", "[x](TRISTAN://pair)"] {
            XCTAssertTrue(links(hostile).isEmpty, "\(hostile) must not stay clickable: a model must not be able to plant a pairing link")
        }
    }

    func testTheLinkTextIsKeptEvenWhenTheLinkIsRemoved() {
        XCTAssertEqual(String(MarkdownInline.attributed("[pair now](tristan://pair?x=1)").characters), "pair now")
    }

    func testInlineStylesAreParsed() {
        let text = MarkdownInline.attributed("**bold** and `code` and *it*")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains(.stronglyEmphasized))
        XCTAssertTrue(intents.contains(.code))
        XCTAssertTrue(intents.contains(.emphasized))
        XCTAssertEqual(String(text.characters), "bold and code and it")
    }

    func testBrokenMarkdownFallsBackToText() {
        XCTAssertEqual(String(MarkdownInline.attributed("**unclosed [link(").characters).isEmpty, false)
    }
}

@MainActor
final class FullScreenControllerTests: XCTestCase {
    func testEntersAndLeavesFullScreenAndRestoresTheWindow() throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.main == nil, "no screen on this machine")
        let window = HUDWindow(contentRect: NSRect(x: 120, y: 140, width: 800, height: 500), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        var applied: [NSApplication.PresentationOptions] = []
        let controller = FullScreenController(window: window) { applied.append($0) }
        let windowed = window.frame
        let screenFrame = try XCTUnwrap(window.screen ?? NSScreen.main).frame

        controller.set(true)
        XCTAssertTrue(controller.isFullScreen)
        XCTAssertEqual(window.frame, screenFrame, "covers the whole screen")
        XCTAssertEqual(applied.last, [.hideDock, .hideMenuBar], "hidden outright, not just auto-hidden")
        XCTAssertGreaterThan(window.level, .mainMenu, "above the menu bar")
        XCTAssertFalse(window.hasShadow)

        controller.set(true)            // doing it twice must not overwrite the saved window frame
        controller.set(false)
        XCTAssertFalse(controller.isFullScreen)
        XCTAssertEqual(window.frame, windowed, "back to where it was")
        XCTAssertEqual(applied.last, [], "Dock and menu bar are given back")
        XCTAssertEqual(window.level, .normal)
        controller.set(false)
        XCTAssertEqual(applied.count, 2, "leaving twice does nothing")
    }
}
