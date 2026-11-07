import XCTest
@testable import TristanCore

final class KidsRoutingTests: XCTestCase {
    func testMustStayLocal() {
        XCTAssertTrue(KidsRouting.mustStayLocal(kidsMode: true, cloudOnce: false))
        XCTAssertFalse(KidsRouting.mustStayLocal(kidsMode: false, cloudOnce: false))
        XCTAssertFalse(KidsRouting.mustStayLocal(kidsMode: false, cloudOnce: true))
        XCTAssertFalse(KidsRouting.mustStayLocal(kidsMode: true, cloudOnce: true))
    }
}
