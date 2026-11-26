import Foundation
import Testing

/// Each app's `TextAccent` (text buttons) reads at 4.5:1 (WCAG AA) on light and dark backgrounds,
/// in the same hue as its brand `AccentColor`; the brand colour itself is unchanged.
@Suite struct TextAccentContrastTests {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// The repository root, from this file's path.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// A colour set's light ("any") and dark colours (dark is light when it has none).
    private static func colors(_ app: String, _ name: String) throws -> (light: RGB, dark: RGB) {
        let url = root.appending(path: "\(app)/Resources/Assets.xcassets/\(name).colorset/Contents.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let json = try #require(object as? [String: Any])
        let entries = try #require(json["colors"] as? [[String: Any]])
        func rgb(_ entry: [String: Any]) throws -> RGB {
            let components = try #require((entry["color"] as? [String: Any])?["components"] as? [String: String])
            func value(_ key: String) throws -> Double {
                let text = try #require(components[key])
                return try #require(Double(text))
            }
            return (try value("red"), try value("green"), try value("blue"))
        }
        let isDark = { (entry: [String: Any]) in
            (entry["appearances"] as? [[String: String]])?.contains { $0["value"] == "dark" } == true
        }
        let lightEntry = try #require(entries.first { !isDark($0) })
        let light = try rgb(lightEntry)
        let dark = try entries.first(where: isDark).map(rgb) ?? light
        return (light, dark)
    }

    private static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    private static func hue(_ c: RGB) -> Double {
        let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b), d = high - low
        guard d > 0 else { return 0 }
        let h: Double = switch high {
        case c.r: (c.g - c.b) / d
        case c.g: (c.b - c.r) / d + 2
        default: (c.r - c.g) / d + 4
        }
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    // White and grouped (#F2F2F7) in light mode; black and grouped cells (#1C1C1E) in dark mode.
    static let lightBackgrounds: [RGB] = [(1, 1, 1), (0xF2 / 255, 0xF2 / 255, 0xF7 / 255)]
    static let darkBackgrounds: [RGB] = [(0, 0, 0), (0x1C / 255, 0x1C / 255, 0x1E / 255)]

    @Test func theContrastFormulaMatchesKnownValues() {
        #expect(abs(Self.contrast((0, 0, 0), (1, 1, 1)) - 21) < 0.01)
        #expect(abs(Self.contrast((1, 1, 1), (1, 1, 1)) - 1) < 0.01)
    }

    @Test(arguments: ["Yomu", "Miru", "Kiku", "Hiku"])
    func textButtonsReadAt4Point5To1(app: String) throws {
        let text = try Self.colors(app, "TextAccent")
        for background in Self.lightBackgrounds {
            #expect(Self.contrast(text.light, background) >= 4.5, "\(app) light")
        }
        for background in Self.darkBackgrounds {
            #expect(Self.contrast(text.dark, background) >= 4.5, "\(app) dark")
        }
    }

    @Test(arguments: ["Yomu", "Miru", "Kiku", "Hiku"])
    func textButtonsKeepTheBrandHue(app: String) throws {
        let text = try Self.colors(app, "TextAccent"), brand = try Self.colors(app, "AccentColor")
        for (t, b) in [(text.light, brand.light), (text.dark, brand.dark)] {
            let difference = abs(Self.hue(t) - Self.hue(b))
            #expect(min(difference, 360 - difference) < 4, "\(app): \(Self.hue(t)) vs \(Self.hue(b))")
        }
    }

    /// Filled buttons' white text reads at 4.5:1 on `FilledAccent` in both modes, in the brand hue.
    @Test(arguments: ["Yomu", "Miru", "Kiku", "Hiku"])
    func whiteTextOnFilledButtonsReads(app: String) throws {
        let fill = try Self.colors(app, "FilledAccent"), brand = try Self.colors(app, "AccentColor")
        for color in [fill.light, fill.dark] {
            #expect(Self.contrast(color, (1, 1, 1)) >= 4.5, "\(app)")
            let difference = abs(Self.hue(color) - Self.hue(brand.light))
            #expect(min(difference, 360 - difference) < 4, "\(app)")
        }
    }

    /// Dark mode keeps the brand colour, apart from Miru's purple, lifted to reach 4.5:1.
    @Test(arguments: ["Yomu", "Kiku", "Hiku"])
    func darkModeKeepsTheBrandColour(app: String) throws {
        let text = try Self.colors(app, "TextAccent"), brand = try Self.colors(app, "AccentColor")
        #expect(abs(text.dark.r - brand.dark.r) < 0.003 && abs(text.dark.g - brand.dark.g) < 0.003 && abs(text.dark.b - brand.dark.b) < 0.003)
    }

    /// Light mode keeps Miru's purple, which already reads at 6:1.
    @Test func miruLightKeepsItsPurple() throws {
        let text = try Self.colors("Miru", "TextAccent"), brand = try Self.colors("Miru", "AccentColor")
        #expect(abs(text.light.r - brand.light.r) < 0.003 && abs(text.light.g - brand.light.g) < 0.003 && abs(text.light.b - brand.light.b) < 0.003)
    }
}
