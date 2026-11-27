import AppKit
import SwiftUI

enum ReaderTheme: String, CaseIterable {
    case white, graphite

    static let preferenceKey = "readerTheme"

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .white
    }

    var title: String { self == .white ? "白色" : "深灰色" }

    @MainActor
    func apply() {
        NSApplication.shared.appearance = NSAppearance(named: self == .white ? .aqua : .darkAqua)
    }
}

enum ReaderPalette {
    static let inkNS = dynamic(light: 0x333335, dark: 0xF8F9FB)
    static let mutedNS = dynamic(light: 0x6D6D6F, dark: 0xC5C7C8)
    static let accentNS = dynamic(light: 0x0064C8, dark: 0x83BFFF)
    static let wordHighlightNS = dynamic(light: 0xDDEBFC, dark: 0x344964)
    static let listeningMarkNS = dynamic(light: 0xB53C47, dark: 0xF28690)

    static let ink = Color(nsColor: inkNS)
    static let paper = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x38373C))
    static let chrome = paper
    static let panel = Color(nsColor: dynamic(light: 0xF9F9F9, dark: 0x3E3E43))
    static let card = Color(nsColor: dynamic(light: 0xFCFCFC, dark: 0x484B4D))
    static let dialog = Color(nsColor: dynamic(light: 0xFBFBFB, dark: 0x424547))
    static let button = Color(nsColor: dynamic(light: 0xEFEFEF, dark: 0x4D4E50))
    static let muted = Color(nsColor: mutedNS)
    static let accent = Color(nsColor: accentNS)
    static let primaryButton = Color(nsColor: dynamic(light: 0x2172E7, dark: 0x1A70C9))
    static let onAccent = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0xF8F9FB))
    static let accentFill = Color(nsColor: dynamic(light: 0xE5E5E5, dark: 0x515157))
    static let rule = Color(nsColor: dynamic(light: 0xD9D9D9, dark: 0x58595B))
    static let disabled = Color(nsColor: dynamic(light: 0xF3F3F3, dark: 0x3E3E43))
    static let warning = Color(nsColor: dynamic(light: 0x815D27, dark: 0xF2C794))

    struct Highlight {
        let ink: NSColor
        let fill: NSColor
    }

    static func highlight(_ style: MarkStyle) -> Highlight {
        switch style {
        case .subject, .evidence: blue
        case .predicate: green
        case .clause, .phrase: amber
        case .modifier, .referring: violet
        case .referent, .background: teal
        case .hint: pink
        case .word: Highlight(ink: inkNS, fill: wordHighlightNS)
        case .listening: Highlight(ink: listeningMarkNS, fill: .clear)
        case .spoken: Highlight(ink: dynamic(light: 0x272923, dark: 0x272923),
                                fill: dynamic(light: 0xFFE477, dark: 0xF7CE55))
        }
    }

    private static let blue = Highlight(
        ink: dynamic(light: 0x0B385D, dark: 0xD5EEFF), fill: dynamic(light: 0xBCDFFB, dark: 0x234E70)
    )
    private static let green = Highlight(
        ink: dynamic(light: 0x173F26, dark: 0xD9F8DC), fill: dynamic(light: 0xBFE8C3, dark: 0x285A38)
    )
    private static let amber = Highlight(
        ink: dynamic(light: 0x5D2C05, dark: 0xFFE6C4), fill: dynamic(light: 0xFBD2A5, dark: 0x71451E)
    )
    private static let violet = Highlight(
        ink: dynamic(light: 0x4C246B, dark: 0xF4DFFF), fill: dynamic(light: 0xE8D3F8, dark: 0x5C3B76)
    )
    private static let teal = Highlight(
        ink: dynamic(light: 0x104046, dark: 0xCCF8F3), fill: dynamic(light: 0xB8E8E2, dark: 0x21565A)
    )
    private static let pink = Highlight(
        ink: dynamic(light: 0x60274B, dark: 0xFFDFEF), fill: dynamic(light: 0xF3D1E4, dark: 0x673D56)
    )

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
    }
}
