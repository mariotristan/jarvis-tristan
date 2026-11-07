import XCTest
@testable import TristanCLICore

final class VersionTests: XCTestCase {
    func testVersionFlagPrintsTheBuildVersion() {
        guard case .stop(let code, let message) = CLI.parse(["--version"]) else { return XCTFail("--version must not run a command") }
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(message, BuildVersion.value)
    }

    /// The committed value; `scripts/package-windows.ps1` overwrites the file with the release version before building.
    func testBuildVersionLooksLikeAVersion() {
        XCTAssertNotNil(BuildVersion.value.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\z"#, options: .regularExpression),
                        BuildVersion.value)
    }
}
