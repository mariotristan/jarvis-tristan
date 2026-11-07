import XCTest
@testable import TristanCore

/// Folder containment with Windows-style paths. These run on the Mac: the Windows rules are pure string logic.
/// 8.3 short names (`C:\PROGRA~1`) are out of scope: they need the file system to expand, and the inputs here come
/// from `SafePath.real`, which resolves through the file system first. An unexpanded short name only ever compares
/// as a different (outside) name, so it fails closed.
final class PathContainmentTests: XCTestCase {
    private func inside(_ root: String, _ path: String) -> Bool {
        PathContainment.contains(root: root, path: path, flavor: .windows)
    }

    func testWindowsContainmentCaseAndSeparators() {
        XCTAssertTrue(inside(#"C:\Work\Proj"#, "c:/work/proj/a.txt"))
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"c:\work\proj\a.txt"#))
        XCTAssertTrue(inside(#"C:\Work\Proj\"#, #"C:\WORK\PROJ\sub\a.txt"#))
        XCTAssertTrue(inside("C:/Work/Proj/", #"C:\Work\Proj\\sub\\a.txt"#))
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"C:\Work\Proj"#), "the root itself counts as inside")
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"C:\Work\Proj\"#))
        XCTAssertTrue(inside(#"C:\"#, #"C:\anything\a.txt"#))
        // Foundation on Windows may report `/C:/Work` from `URL.path`.
        XCTAssertTrue(inside("/C:/Work/Proj", #"C:\Work\Proj\a.txt"#))
        // A different drive is outside.
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"D:\Work\Proj\a.txt"#))
        // Case folding is ASCII only: NTFS names that differ outside ASCII are compared exactly (fails closed).
        XCTAssertTrue(inside(#"C:\Work\Ünï"#, #"C:\WORK\Ünï\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Straße"#, #"C:\Work\STRASSE\a.txt"#))
        XCTAssertFalse(inside("C:\\Work\\Caf\u{e9}", "C:\\Work\\Cafe\u{301}\\a.txt"), "no Unicode normalisation")
    }

    func testWindowsSiblingPrefixIsOutside() {
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"C:\Work\Proj-evil\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"C:\Work\Projx"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"C:\Work"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"C:\Work\Pro"#))
    }

    func testWindowsDotDotEscapes() {
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"C:\Work\Proj\..\Other"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"C:\Work\Proj\..\Proj-evil\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, "C:/Work/Proj/sub/../../Other/a.txt"))
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"C:\Work\Proj\sub\..\a.txt"#))
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"C:\Work\Proj\.\a.txt"#))
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"C:\Work\Other\..\Proj\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"C:\..\..\Work\Proj\a.txt"#), "climbing above the drive root is rejected")
        XCTAssertFalse(inside(#"C:\Work\Proj\..\Other"#, #"C:\Work\Proj\a.txt"#), "the root is normalised too")
    }

    func testUNCOnlyMatchesSameShare() {
        let root = #"\\server\share\Proj"#
        XCTAssertTrue(inside(root, #"\\SERVER\Share\proj\a.txt"#))
        XCTAssertTrue(inside(root, "//server/share/Proj/a.txt"))
        XCTAssertFalse(inside(root, #"\\server\other\Proj\a.txt"#))
        XCTAssertFalse(inside(root, #"\\server2\share\Proj\a.txt"#))
        XCTAssertFalse(inside(root, #"\\server\share\Proj-evil\a.txt"#))
        XCTAssertFalse(inside(root, #"\\server\share\Proj\..\..\other\Proj\a.txt"#))
        XCTAssertFalse(inside(root, #"\\server\share\..\other\Proj\a.txt"#))
        // A UNC path is never inside a drive root and vice versa.
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\\server\share\Proj\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\\localhost\C$\Work\Proj\a.txt"#))
        XCTAssertFalse(inside(root, #"C:\server\share\Proj\a.txt"#))
        // `\\server` alone or with an empty share is not a root.
        XCTAssertFalse(inside(#"\\server"#, #"\\server\share\a.txt"#))
        XCTAssertFalse(inside(#"\\server\share"#, #"\\\share\a.txt"#))
    }

    func testDevicePrefixesNormaliseToDriveForm() {
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"\\?\C:\Work\Proj\a.txt"#))
        XCTAssertTrue(inside(#"\\?\C:\Work\Proj"#, #"c:\work\proj\a.txt"#))
        XCTAssertTrue(inside(#"C:\Work\Proj"#, #"\\.\C:\Work\Proj\a.txt"#))
        XCTAssertTrue(inside(#"\\server\share\Proj"#, #"\\?\UNC\server\share\Proj\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\\?\UNC\server\share\Proj\a.txt"#))
        // `\\?\` paths are not normalised by Windows: dot segments and forward slashes fail closed.
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\\?\C:\Work\Proj\sub\..\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\\?\C:/Work/Proj/a.txt"#))
        // Other device namespaces (volume GUIDs, NT object paths, raw devices) are never inside anything.
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\\?\Volume{12345678-1234-1234-1234-123456789abc}\Work\Proj\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\??\C:\Work\Proj\a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj"#, #"\\.\PhysicalDrive0"#))
    }

    func testWindowsRejectsAmbiguousForms() {
        let root = #"C:\Work\Proj"#
        XCTAssertFalse(inside(root, "C:\\Work\\Proj\\a\0.txt"), "NUL")
        XCTAssertFalse(inside("C:\\Work\\Proj\0", #"C:\Work\Proj\a.txt"#), "NUL in the root")
        XCTAssertFalse(inside(root, "C:Work\\Proj\\a.txt"), "drive-relative")
        XCTAssertFalse(inside(root, "C:"), "drive-relative")
        XCTAssertFalse(inside(root, #"\Work\Proj\a.txt"#), "root-relative (current drive)")
        XCTAssertFalse(inside(root, #"Work\Proj\a.txt"#), "relative")
        XCTAssertFalse(inside(root, #"C:\Work\Proj\a.txt:stream"#), "alternate data stream")
        XCTAssertFalse(inside(root, #"C:\Work\Proj:stream"#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj\a*.txt"#), "wildcard")
        XCTAssertFalse(inside(root, #"C:\Work\Proj\NUL"#), "reserved device name")
        XCTAssertFalse(inside(root, #"C:\Work\Proj\con.txt"#), "reserved device name with an extension")
        XCTAssertFalse(inside(root, #"C:\Work\Proj\COM1"#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj\lpt9.log"#))
        XCTAssertTrue(inside(root, #"C:\Work\Proj\console.txt"#), "only exact device names are reserved")
    }

    /// Win32 strips trailing dots and spaces from some segments (`C:\Work\Proj.` opens `C:\Work\Proj`) but NTFS can
    /// also hold real names ending in them (a sibling `C:\Work\Proj ` folder). Modelling the rule exactly is fragile,
    /// so any segment ending in a dot or a space fails closed: the action asks.
    func testTrailingDotsAndSpacesFailClosed() {
        let root = #"C:\Work\Proj"#
        XCTAssertFalse(inside(root, #"C:\Work\Proj."#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj.\a.txt"#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj\ "#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj \a.txt"#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj\a.txt."#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj\...\a.txt"#))
        XCTAssertFalse(inside(root, #"C:\Work\Proj\.. \a.txt"#))
        XCTAssertFalse(inside(#"C:\Work\Proj."#, #"C:\Work\Proj.\a.txt"#), "a root ending in a dot contains nothing")
    }

    func testStrictlyInsideExcludesTheRoot() {
        XCTAssertFalse(PathContainment.isStrictlyInside(root: #"C:\Work\Proj"#, path: #"c:\work\proj\"#, flavor: .windows))
        XCTAssertTrue(PathContainment.isStrictlyInside(root: #"C:\Work\Proj"#, path: #"c:\work\proj\a"#, flavor: .windows))
        XCTAssertFalse(PathContainment.isStrictlyInside(root: "/w/p", path: "/w/p", flavor: .posix))
        XCTAssertTrue(PathContainment.isStrictlyInside(root: "/w/p", path: "/w/p/a", flavor: .posix))
    }

    /// The posix flavor is exactly today's check: equal, or a string prefix ending in `/`. Nothing is case-folded.
    func testPosixKeepsTodaysBehaviour() {
        XCTAssertTrue(PathContainment.contains(root: "/w/p", path: "/w/p", flavor: .posix))
        XCTAssertTrue(PathContainment.contains(root: "/w/p", path: "/w/p/a", flavor: .posix))
        XCTAssertFalse(PathContainment.contains(root: "/w/p", path: "/w/p-evil/a", flavor: .posix))
        XCTAssertFalse(PathContainment.contains(root: "/w/p", path: "/W/P/a", flavor: .posix))
        XCTAssertFalse(PathContainment.contains(root: "/w/p", path: #"/w/p\..\..\etc"#, flavor: .posix), "`\\` is not a separator")
    }

    func testInputForms() {
        XCTAssertEqual(PathContainment.form(of: #"C:\x"#, flavor: .windows), .absolute)
        XCTAssertEqual(PathContainment.form(of: "c:/x", flavor: .windows), .absolute)
        XCTAssertEqual(PathContainment.form(of: #"\\server\share\x"#, flavor: .windows), .absolute)
        XCTAssertEqual(PathContainment.form(of: "C:foo", flavor: .windows), .rejected)
        XCTAssertEqual(PathContainment.form(of: "C:", flavor: .windows), .rejected)
        XCTAssertEqual(PathContainment.form(of: #"\foo"#, flavor: .windows), .rejected)
        XCTAssertEqual(PathContainment.form(of: "/foo", flavor: .windows), .rejected)
        XCTAssertEqual(PathContainment.form(of: "a\0b", flavor: .windows), .rejected)
        XCTAssertEqual(PathContainment.form(of: #"src\a.txt"#, flavor: .windows), .relative)
        XCTAssertEqual(PathContainment.form(of: "/foo", flavor: .posix), .absolute)
        XCTAssertEqual(PathContainment.form(of: "C:foo", flavor: .posix), .relative)
    }

    func testSandboxRejectsWindowsFormsBeforeTouchingTheDisk() {
        let sandbox = ToolSandbox(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertNil(sandbox.resolve("C:foo", flavor: .windows))
        XCTAssertNil(sandbox.resolve(#"\Windows\System32"#, flavor: .windows))
        XCTAssertNil(sandbox.resolve(#"C:\Windows\System32\drivers\etc\hosts"#, flavor: .windows))
    }
}
