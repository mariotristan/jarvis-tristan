import XCTest
@testable import Tristan

final class SpokenAnswerTests: XCTestCase {
    func testShortFactualAnswersAreSpoken() {
        XCTAssertEqual(SpokenAnswer.line(for: "The biggest planet is Jupiter."), "The biggest planet is Jupiter.")
        XCTAssertEqual(SpokenAnswer.line(for: "  1 + 1 is 2.\n"), "1 + 1 is 2.")
    }

    func testCodeIsNeverSpoken() {
        XCTAssertNil(SpokenAnswer.line(for: "```swift\nlet x = 1\n```"))
        XCTAssertNil(SpokenAnswer.line(for: "Use `swift test` to run them."))
    }

    func testLongAnswersAreNotSpoken() {
        XCTAssertNil(SpokenAnswer.line(for: String(repeating: "word ", count: 60)))
        XCTAssertNil(SpokenAnswer.line(for: "One.\nTwo.\nThree.\nFour."))
        XCTAssertNil(SpokenAnswer.line(for: "   "))
    }

    func testThreeShortLinesAreStillSpoken() {
        XCTAssertNotNil(SpokenAnswer.line(for: "One.\nTwo.\nThree."))
    }

    func testLaunchFactsAreChosenPerMode() {
        XCTAssertTrue(Greeting.facts.contains(Greeting.fact(kids: false)))
        XCTAssertTrue(Greeting.kidsFacts.contains(Greeting.fact(kids: true)))
        XCTAssertEqual(Greeting.fact(kids: false, seed: 3), Greeting.facts[3])
        XCTAssertEqual(Greeting.fact(kids: true, seed: 13), Greeting.kidsFacts[3])
    }
}
