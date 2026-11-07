import XCTest
@testable import TristanCore

// Moved from Tests/TristanTests/MarkdownTests.swift so the Windows CI runs it.

final class CodeFenceTests: XCTestCase {
    func testLanguageNamesFromExtensions() {
        XCTAssertEqual(CodeFence.language(forPath: "README.md"), "markdown")
        XCTAssertEqual(CodeFence.language(forPath: "src/app.ts"), "typescript")
        XCTAssertEqual(CodeFence.language(forPath: "a/b/Main.swift"), "swift")
        XCTAssertEqual(CodeFence.language(forPath: "Makefile"), "text")
        XCTAssertTrue(CodeFence.isMarkdown("Markdown") && CodeFence.isMarkdown("md") && !CodeFence.isMarkdown("swift"))
    }
}
