import XCTest
@testable import Tristan

final class ThemeTests: XCTestCase {
    func testEveryPaletteIsReadable() {
        for palette in ThemeStore.all {
            let roles: [(String, Hex)] = [("primary", palette.primary), ("accent", palette.accent), ("good", palette.good),
                                          ("bad", palette.bad), ("prose", palette.prose)]
            for (role, color) in roles {
                for background in [palette.deep, palette.glow, palette.panel] {
                    let ratio = color.contrast(with: background)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(palette.name): \(role) on \(String(background.value, radix: 16)) is \(ratio)")
                }
            }
        }
    }

    func testDarkFlagMatchesBackground() {
        for palette in ThemeStore.all {
            XCTAssertEqual(palette.dark, palette.deep.luminance < 0.4, palette.name)
        }
    }

    func testKeysAreUniqueAndGroupsExist() {
        XCTAssertEqual(Set(ThemeStore.all.map(\.id)).count, ThemeStore.all.count)
        for palette in ThemeStore.all { XCTAssertTrue(ThemeStore.groups.contains(palette.group), palette.name) }
    }

    func testResolve() {
        XCTAssertEqual(ThemeStore.resolve("auto", systemIsDark: true).id, "tristan")
        XCTAssertEqual(ThemeStore.resolve("auto", systemIsDark: false).id, "light")
        XCTAssertEqual(ThemeStore.resolve("nord", systemIsDark: false).id, "nord")
        XCTAssertEqual(ThemeStore.resolve("gone", systemIsDark: true).id, "tristan")
    }
}
