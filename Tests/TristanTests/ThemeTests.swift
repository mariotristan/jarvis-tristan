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

    func testThePrideThemeExistsWithAWelcomeAndSixRainbowColors() {
        let pride = ThemeStore.palette(for: ThemeStore.prideKey)
        XCTAssertNotNil(pride)
        XCTAssertEqual(pride?.group, "Pride")
        XCTAssertEqual(Rainbow.colors.count, 6, "the six colors of the flag")
        XCTAssertGreaterThanOrEqual(ThemeStore.welcomes[ThemeStore.prideKey]?.count ?? 0, 2)
        let saved = ThemeStore.palette
        defer { ThemeStore.palette = saved }
        ThemeStore.palette = pride!
        XCTAssertTrue(ThemeStore.isPride)
        ThemeStore.palette = ThemeStore.all[0]
        XCTAssertFalse(ThemeStore.isPride)
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

    func testEveryThemeHasWelcomes() {
        for palette in ThemeStore.all {
            let lines = ThemeStore.welcomes[palette.id] ?? []
            XCTAssertGreaterThanOrEqual(lines.count, 2, palette.name)
            XCTAssertFalse(lines.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }, palette.name)
        }
        XCTAssertEqual(Set(ThemeStore.welcomes.keys), Set(ThemeStore.all.map(\.id)))
    }

    func testWelcomeIsStablePerSeedAndFallsBack() {
        XCTAssertEqual(ThemeStore.welcome(for: "matrix", seed: 7), ThemeStore.welcome(for: "matrix", seed: 7))
        XCTAssertNotEqual(ThemeStore.welcome(for: "matrix", seed: 0), ThemeStore.welcome(for: "matrix", seed: 1))
        XCTAssertEqual(ThemeStore.welcome(for: "nope", seed: 3), "Awaiting orders, sir.")
    }
}
