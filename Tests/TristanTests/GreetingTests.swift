import XCTest
@testable import Tristan
@testable import TristanCore

final class GreetingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 5) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testPartsOfTheDay() {
        XCTAssertEqual(Greeting.part(hour: 5), .morning)
        XCTAssertEqual(Greeting.part(hour: 11), .morning)
        XCTAssertEqual(Greeting.part(hour: 12), .afternoon)
        XCTAssertEqual(Greeting.part(hour: 17), .evening)
        XCTAssertEqual(Greeting.part(hour: 22), .night)
        XCTAssertEqual(Greeting.part(hour: 3), .night)
    }

    func testLineHasTimeAndWeekdayAndIsStable() {
        let monday = date(11, 2, 7, 42)       // Monday 2 November 2026
        let line = Greeting.line(at: monday, calendar: calendar)
        XCTAssertTrue(line.contains("7:42 AM"), line)
        XCTAssertTrue(line.contains("Monday"), line)
        XCTAssertEqual(line, Greeting.line(at: monday, calendar: calendar))
    }

    func testOpeningMatchesTheHour() {
        for hour in 0..<24 {
            let line = Greeting.line(at: date(11, 2, hour), calendar: calendar)
            let options = Greeting.openers[Greeting.part(hour: hour)]!
            XCTAssertTrue(options.contains { line.hasPrefix($0) }, "\(hour): \(line)")
        }
    }

    func testLinesVaryAcrossHoursAndDays() {
        let hours = Set((0..<24).map { Greeting.line(at: date(11, 2, $0), calendar: calendar) })
        let days = Set((1...28).map { Greeting.line(at: date(11, $0, 9), calendar: calendar) })
        XCTAssertGreaterThan(hours.count, 12)
        XCTAssertGreaterThan(days.count, 7)
    }

    func testEveryWeekdayHasARemark() {
        for weekday in 1...7 { XCTAssertFalse((Greeting.dayRemarks[weekday] ?? []).isEmpty, "\(weekday)") }
    }
}
