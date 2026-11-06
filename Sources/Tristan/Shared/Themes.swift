import SwiftUI

/// A color given as 0xRRGGBB, kept as a number so its contrast can be checked.
struct Hex: Equatable {
    let value: UInt32
    init(_ value: UInt32) { self.value = value }
    var color: Color { Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255) }
    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ v: UInt32) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(value >> 16 & 0xFF) + 0.7152 * lin(value >> 8 & 0xFF) + 0.0722 * lin(value & 0xFF)
    }
    func contrast(with other: Hex) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// One look for the HUD: the roles the interface paints with. The names match `Theme`.
struct ThemePalette: Identifiable, Equatable {
    let id: String
    let name: String
    let group: String
    let dark: Bool
    let primary: Hex     // main text, borders, the reactor
    let accent: Hex      // captions, warnings, approvals
    let good: Hex
    let bad: Hex
    let deep: Hex        // window background
    let glow: Hex        // lighter center of the backdrop
    let panel: Hex
    let prose: Hex       // body text

    init(_ id: String, _ name: String, _ group: String, dark: Bool = true,
         primary: UInt32, accent: UInt32, good: UInt32, bad: UInt32,
         deep: UInt32, glow: UInt32, panel: UInt32, prose: UInt32) {
        self.id = id; self.name = name; self.group = group; self.dark = dark
        self.primary = Hex(primary); self.accent = Hex(accent); self.good = Hex(good); self.bad = Hex(bad)
        self.deep = Hex(deep); self.glow = Hex(glow); self.panel = Hex(panel); self.prose = Hex(prose)
    }
}

/// The palettes, and which one is in use. Colors are read when a view is built, so the HUD rebuilds when the choice
/// changes. Palettes come from each look's published colors; where one is under 4.5:1 on its own background, the role
/// uses a lighter or darker shade of the same hue (ThemeTests checks every palette).
enum ThemeStore {
    static let autoKey = "auto"
    static let defaultKey = "tristan"
    static let groups = ["Everyday", "Dark classics", "Light classics"]

    static let all: [ThemePalette] = [
        ThemePalette("tristan", "Tristan", "Everyday", primary: 0x1AD4F0, accent: 0xFFB347, good: 0x9EFFB0, bad: 0xFF5252,
                     deep: 0x020B10, glow: 0x052130, panel: 0x031A24, prose: 0xD6F5FF),
        ThemePalette("deepblue", "Deep Blue", "Everyday", primary: 0x1BE1F2, accent: 0xFFD166, good: 0x7CF5A8, bad: 0xFF8A8A,
                     deep: 0x00154F, glow: 0x002FAF, panel: 0x00268C, prose: 0xDCE6FF),
        ThemePalette("graphite", "Graphite", "Everyday", primary: 0xD4D4D8, accent: 0xF5C06B, good: 0x8BD5A0, bad: 0xF2777A,
                     deep: 0x0E0E10, glow: 0x222226, panel: 0x18181B, prose: 0xE4E4E7),
        ThemePalette("light", "Light", "Everyday", dark: false, primary: 0x0B5BE0, accent: 0x9A4A00, good: 0x0F7B3F, bad: 0xC62828,
                     deep: 0xF3F6FB, glow: 0xFFFFFF, panel: 0xFFFFFF, prose: 0x1A1F2E),
        ThemePalette("contrast", "High contrast", "Everyday", dark: false, primary: 0x002FAF, accent: 0x7A3E00, good: 0x006B2D, bad: 0xB00020,
                     deep: 0xFFFFFF, glow: 0xFFFFFF, panel: 0xFFFFFF, prose: 0x000000),
        ThemePalette("tron", "Tron", "Dark classics", primary: 0x00E5FF, accent: 0xFF8A1F, good: 0x7CFFB2, bad: 0xFF4D4D,
                     deep: 0x02070B, glow: 0x0A1F2B, panel: 0x061219, prose: 0xE6FCFF),
        ThemePalette("dracula", "Dracula", "Dark classics", primary: 0xBD93F9, accent: 0xFFB86C, good: 0x50FA7B, bad: 0xFF7F7F,
                     deep: 0x21222C, glow: 0x343746, panel: 0x282A36, prose: 0xF8F8F2),
        ThemePalette("nord", "Nord", "Dark classics", primary: 0x88C0D0, accent: 0xEBCB8B, good: 0xA3BE8C, bad: 0xEE9AA3,
                     deep: 0x2E3440, glow: 0x363C4A, panel: 0x272C36, prose: 0xE5E9F0),
        ThemePalette("tokyonight", "Tokyo Night", "Dark classics", primary: 0x7AA2F7, accent: 0xE0AF68, good: 0x9ECE6A, bad: 0xF7768E,
                     deep: 0x1A1B26, glow: 0x24283B, panel: 0x16161E, prose: 0xC0CAF5),
        ThemePalette("catppuccin", "Catppuccin", "Dark classics", primary: 0xCBA6F7, accent: 0xF9E2AF, good: 0xA6E3A1, bad: 0xF38BA8,
                     deep: 0x1E1E2E, glow: 0x313244, panel: 0x181825, prose: 0xCDD6F4),
        ThemePalette("gruvbox", "Gruvbox", "Dark classics", primary: 0x9DBFB0, accent: 0xFABD2F, good: 0xB8BB26, bad: 0xFF7260,
                     deep: 0x282828, glow: 0x34312F, panel: 0x1D2021, prose: 0xEBDBB2),
        ThemePalette("solarized", "Solarized Dark", "Dark classics", primary: 0x3DB8AE, accent: 0xD0A21A, good: 0x9DB300, bad: 0xFF7570,
                     deep: 0x002B36, glow: 0x04303B, panel: 0x00212B, prose: 0xA8B8B8),
        ThemePalette("monokai", "Monokai", "Dark classics", primary: 0x66D9EF, accent: 0xE6DB74, good: 0xA6E22E, bad: 0xFF6FA0,
                     deep: 0x272822, glow: 0x34342B, panel: 0x1E1F1C, prose: 0xF8F8F2),
        ThemePalette("rosepine", "Rosé Pine", "Dark classics", primary: 0xC4A7E7, accent: 0xF6C177, good: 0x9CCFD8, bad: 0xEB6F92,
                     deep: 0x191724, glow: 0x26233A, panel: 0x1F1D2E, prose: 0xE0DEF4),
        ThemePalette("githublight", "GitHub Light", "Light classics", dark: false, primary: 0x0969DA, accent: 0x8A5A00, good: 0x1A7F37, bad: 0xCF222E,
                     deep: 0xFFFFFF, glow: 0xF6F8FA, panel: 0xF6F8FA, prose: 0x1F2328),
        ThemePalette("solarizedlight", "Solarized Light", "Light classics", dark: false, primary: 0x1A6A9C, accent: 0x7A5700, good: 0x566A00, bad: 0xC0282B,
                     deep: 0xFDF6E3, glow: 0xFFFBEF, panel: 0xEEE8D5, prose: 0x43565D),
        ThemePalette("latte", "Catppuccin Latte", "Light classics", dark: false, primary: 0x1E5FE0, accent: 0x8F5400, good: 0x246E19, bad: 0xC8103A,
                     deep: 0xEFF1F5, glow: 0xFFFFFF, panel: 0xE6E9EF, prose: 0x4C4F69),
    ]

    /// The palette in use. Set from the main thread, before the views that read it are built.
    nonisolated(unsafe) static var palette: ThemePalette = all[0]

    static func palette(for key: String) -> ThemePalette? { all.first { $0.id == key } }

    /// What a saved choice means right now: "auto" follows the system appearance; an unknown key falls back to Tristan.
    static func resolve(_ choice: String, systemIsDark: Bool) -> ThemePalette {
        if choice == autoKey { return palette(for: systemIsDark ? "tristan" : "light")! }
        return palette(for: choice) ?? all[0]
    }
}
