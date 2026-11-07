import XCTest
@testable import TristanCore

final class ParentPINTests: XCTestCase {
    func testHashIsStable() {
        XCTAssertEqual(ParentPIN.hash("1234"), "beb849fcaa5db51932402b68187c8c471772913d3da2f1d17d1653d8c08b90be")
    }
}
