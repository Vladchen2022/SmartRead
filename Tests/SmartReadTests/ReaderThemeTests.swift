import AppKit
import XCTest
@testable import SmartRead

final class ReaderThemeTests: XCTestCase {
    func testDefaultAndSavedTheme() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReaderTheme.saved(in: defaults), .white)
        for theme in ReaderTheme.allCases {
            defaults.set(theme.rawValue, forKey: ReaderTheme.preferenceKey)
            XCTAssertEqual(ReaderTheme.saved(in: defaults), theme)
        }
        defaults.set("obsolete", forKey: ReaderTheme.preferenceKey)
        XCTAssertEqual(ReaderTheme.saved(in: defaults), .white)
    }

    @MainActor
    func testOpenSubtitleAndNewWindowInheritEachTheme() throws {
        let application = NSApplication.shared
        let previous = application.appearance
        defer { application.appearance = previous }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let subtitle = SubtitleWordView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView = subtitle
        subtitle.configure(text: "A quiet morning.", fontSize: 25, selectedWord: nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = try XCTUnwrap(subtitle.renderedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        for theme in [ReaderTheme.graphite, .white] {
            theme.apply()
            let expected: NSAppearance.Name = theme == .white ? .aqua : .darkAqua
            XCTAssertEqual(subtitle.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
            let second = NSWindow()
            second.isReleasedWhenClosed = false
            XCTAssertEqual(second.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
            second.close()
            var resolved: NSColor?
            subtitle.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = text.usingColorSpace(.sRGB) }
            let srgb = try XCTUnwrap(resolved)
            let rgb = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map { Int(($0 * 255).rounded()) }
            XCTAssertEqual(rgb, theme == .white ? [51, 51, 53] : [248, 249, 251])
        }
    }
}
