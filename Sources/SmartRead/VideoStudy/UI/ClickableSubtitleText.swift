import AppKit
import SwiftUI

struct ClickableSubtitleText: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let selectedWord: SubtitleWord?
    var segments: [SubtitleReadingSegment] = []
    var contentIdentity: String? = nil
    var alignment: NSTextAlignment = .center
    var usesSerif = false
    var foreground: NSColor? = nil
    var listeningMarks: [NSRange] = []
    var onSelectionBegan: (() -> Void)? = nil
    let onWordClick: (SubtitleWord, String) -> Void

    func makeNSView(context: Context) -> SubtitleWordView {
        SubtitleWordView()
    }

    func updateNSView(_ view: SubtitleWordView, context: Context) {
        view.onWordClick = onWordClick
        view.onSelectionBegan = onSelectionBegan
        view.configure(text: text, fontSize: fontSize, selectedWord: selectedWord,
            segments: segments, contentIdentity: contentIdentity,
            alignment: alignment, usesSerif: usesSerif, foreground: foreground, listeningMarks: listeningMarks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SubtitleWordView, context: Context) -> CGSize? {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: nsView.textHeight(for: width))
    }
}

// TextKit preserves ordinary sentence spacing and wrapping. Hit-testing uses
// glyph rectangles rather than the nearest character, so blank space never
// turns into a click on an adjacent word.
@MainActor
final class SubtitleWordView: NSView {
    var onWordClick: ((SubtitleWord, String) -> Void)?
    var onSelectionBegan: (() -> Void)?
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var text = ""
    private var fontSize: CGFloat = 30
    private var selectedWord: SubtitleWord?
    private var segments: [SubtitleReadingSegment] = []
    private var contentIdentity: String?
    private var alignment: NSTextAlignment = .center
    private var usesSerif = false
    private var foreground: NSColor?
    private var listeningMarks: [NSRange] = []
    private var hoveredWord: SubtitleWord?
    private var pressedWord: SubtitleWord?
    private var draggedSelection: SubtitleWord?
    private var tracking: NSTrackingArea?
    private var words: [SubtitleWord] = []

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("英文字幕")
        setAccessibilityHelp("点击单词或拖选最多八个词的短语，暂停并查询当前语境中的意思")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, fontSize: CGFloat, selectedWord: SubtitleWord?,
                   segments: [SubtitleReadingSegment] = [], contentIdentity: String? = nil,
                   alignment: NSTextAlignment = .center, usesSerif: Bool = false, foreground: NSColor? = nil,
                   listeningMarks: [NSRange] = []) {
        guard self.text != text || self.fontSize != fontSize || self.selectedWord != selectedWord
            || self.segments != segments || self.contentIdentity != contentIdentity
            || self.alignment != alignment || self.usesSerif != usesSerif || self.foreground != foreground
            || self.listeningMarks != listeningMarks else { return }
        let changedText = self.text != text || self.contentIdentity != contentIdentity
        self.text = text
        self.fontSize = fontSize
        self.selectedWord = selectedWord
        self.contentIdentity = contentIdentity
        self.alignment = alignment
        self.usesSerif = usesSerif
        self.foreground = foreground
        let length = (text as NSString).length
        self.listeningMarks = listeningMarks.filter {
            $0.location >= 0 && $0.location <= length && $0.length > 0 && $0.length <= length - $0.location
        }
        self.segments = segments.filter { $0.range.location >= 0 && $0.range.location <= length && $0.range.length <= length - $0.range.location }
        words = SubtitleWordTokenizer.words(in: text)
        setAccessibilityValue(text)
        if segments.isEmpty {
            setAccessibilityHelp("点击单词或拖选最多八个词的短语，暂停并查询当前语境中的意思")
        } else {
            let current = segments.filter { $0.phase == .current }.map(\.cue.text).joined(separator: "；")
            setAccessibilityHelp("整句阅读；当前片段：\(current.isEmpty ? "字幕间隔" : current)。蓝色为当前片段，灰色片段也可点词。")
        }
        if changedText {
            hoveredWord = nil
            pressedWord = nil
            draggedSelection = nil
        }
        rebuildAttributes()
        needsLayout = true
        needsDisplay = true
    }

    private func rebuildAttributes() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let defaultFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let font = usesSerif ? NSFont(name: "Georgia", size: fontSize) ?? defaultFont : defaultFont
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: foreground ?? ReaderPalette.inkNS,
            .paragraphStyle: paragraph
        ]))
        // Color-only changes preserve glyph widths, wrapping and sentence position.
        // Do not bold only the active cue: that would move the following words.
        for segment in segments {
            let color: NSColor = switch segment.phase {
            case .current: ReaderPalette.accentNS
            case .past: ReaderPalette.inkNS.withAlphaComponent(0.80)
            case .upcoming: ReaderPalette.mutedNS
            }
            storage.addAttribute(.foregroundColor, value: color, range: segment.range)
        }
        if let selectedWord = draggedSelection ?? selectedWord,
           SubtitleWordTokenizer.isValidTarget(selectedWord, in: text) {
            storage.addAttribute(.backgroundColor, value: ReaderPalette.wordHighlightNS, range: selectedWord.range)
            storage.addAttribute(.foregroundColor, value: ReaderPalette.inkNS, range: selectedWord.range)
        }
        if let hoveredWord {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: hoveredWord.range)
        }
        for range in listeningMarks {
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .underlineColor: ReaderPalette.listeningMarkNS], range: range)
        }
    }

    var renderedText: NSAttributedString { NSAttributedString(attributedString: storage) }

    func textHeight(for width: CGFloat) -> CGFloat {
        container.size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return max(ceil(manager.usedRect(for: container).height), ceil(fontSize * 1.2))
    }

    private var textOrigin: NSPoint {
        let height = textHeight(for: bounds.width)
        return NSPoint(x: 0, y: max(0, (bounds.height - height) / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let origin = textOrigin
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    override func layout() {
        super.layout()
        _ = textHeight(for: bounds.width)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func word(at point: NSPoint) -> SubtitleWord? {
        let origin = textOrigin
        let textPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard manager.numberOfGlyphs > 0 else { return nil }
        let glyph = manager.glyphIndex(for: textPoint, in: container)
        let drawn = manager.glyphRange(for: container)
        guard NSLocationInRange(glyph, drawn),
              !NSLocationInRange(glyph, manager.truncatedGlyphRange(inLineFragmentForGlyphAt: glyph)) else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(textPoint) else { return nil }
        let character = manager.characterIndexForGlyph(at: glyph)
        return words.first { NSLocationInRange(character, $0.range) }
    }

    override func mouseDown(with event: NSEvent) {
        pressedWord = word(at: convert(event.locationInWindow, from: nil))
        draggedSelection = nil
        if pressedWord != nil { onSelectionBegan?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let first = pressedWord,
              let last = word(at: convert(event.locationInWindow, from: nil)) else { return }
        draggedSelection = SubtitleWordTokenizer.selection(in: text, from: first, to: last)
        rebuildAttributes()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedWord = nil
            draggedSelection = nil
            rebuildAttributes()
            needsDisplay = true
        }
        guard let first = pressedWord,
              let last = word(at: convert(event.locationInWindow, from: nil)),
              let selection = SubtitleWordTokenizer.selection(in: text, from: first, to: last) else { return }
        onWordClick?(selection, text)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(word(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    private func updateHover(_ word: SubtitleWord?) {
        guard word != hoveredWord else { return }
        hoveredWord = word
        rebuildAttributes()
        needsDisplay = true
    }

    private func rectangles(for word: SubtitleWord) -> [NSRect] {
        let origin = textOrigin
        let glyphs = manager.glyphRange(forCharacterRange: word.range, actualCharacterRange: nil)
        let drawn = manager.glyphRange(for: container)
        let visible = NSIntersectionRange(glyphs, drawn)
        guard visible.length > 0 else { return [] }
        var rectangles: [NSRect] = []
        manager.enumerateLineFragments(forGlyphRange: visible) { _, _, _, lineGlyphs, _ in
            let range = NSIntersectionRange(visible, lineGlyphs)
            guard range.length > 0 else { return }
            let truncated = self.manager.truncatedGlyphRange(inLineFragmentForGlyphAt: range.location)
            guard NSIntersectionRange(range, truncated).length == 0 else { return }
            let rect = self.manager.boundingRect(forGlyphRange: range, in: self.container)
            rectangles.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rectangles
    }

    override func resetCursorRects() {
        for word in words {
            for rect in rectangles(for: word) { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        words.compactMap { word in
            guard let rect = rectangles(for: word).first else { return nil }
            let element = SubtitleWordAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(word.text)
            let phase = segments.first { NSIntersectionRange($0.range, word.range).length > 0 }?.phase
            let description = phase.map { $0 == .current ? "当前片段" : $0 == .past ? "已播放片段" : "未播放片段" }
            element.setAccessibilityHelp("查询单词：\(word.text)\(description.map { "（\($0)）" } ?? "")")
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            }
            element.press = { [weak self] in
                guard let self else { return }
                onWordClick?(word, text)
            }
            return element
        }
    }
}

private final class SubtitleWordAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        press?()
        return true
    }
}
