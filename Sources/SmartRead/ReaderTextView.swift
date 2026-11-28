import AppKit
import SmartReadSync
import SwiftUI

struct ListeningFocus: Equatable {
    let request: ReaderSpeech.FocusRequest
    let paragraph: NSRange
}

struct ReaderFigure: Equatable {
    let index: Int
    let placement: ReadingPDFFigure
    let image: CGImage?
}

struct ReaderTextView: NSViewRepresentable {
    let bodyText: String
    let version: UUID
    let fontSize: Double
    let marks: [ReaderMark]
    let listeningMarks: [TextListeningMark]
    let inlineTranslation: InlineTranslation?
    var figures: [ReaderFigure] = []
    var onOpenFigure: (Int) -> Void = { _ in }
    let jump: ReadingJump?
    let listeningFocus: ListeningFocus?
    let maskOpacity: Double
    let highlightsSpeech: Bool
    let interfaceScale: CGFloat
    let onListeningFocusArrived: (UUID) -> Void
    let wordAction: SelectionActions.WordAction?
    let onSelection: (TextExcerpt?) -> Void
    let onUserSelection: (TextExcerpt) -> Void
    let allowsLanguageActions: (TextExcerpt) -> Bool
    let onUserPhraseSelection: (TextExcerpt) -> Void
    let onTranslateSelection: (TextExcerpt) -> Void
    let onTextClick: (Int) -> Bool
    let onReadingPosition: (Int, UUID, Bool) -> Void
    let onCloseInline: () -> Void
    let onTranslateSentence: (TextExcerpt) -> Void
    let onSpeakSelection: (TextExcerpt) -> Void
    let onCancelMark: (UUID) -> Void
    let onWordStudy: (StudyKind, TextExcerpt) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .automatic
        scroll.contentView.postsBoundsChangedNotifications = true

        let view = ClickableTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(ReaderLayoutManager())
        view.frame = scroll.bounds
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.usesAdaptiveColorMappingForDarkAppearance = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = NSSize(width: 4, height: 16)
        view.setAccessibilityLabel("文章正文")
        view.delegate = context.coordinator
        view.onCloseInline = { [weak coordinator = context.coordinator] in coordinator?.parent.onCloseInline() }
        scroll.documentView = view
        let surface = ReadingSurface(scroll: scroll, text: view)
        surface.allowsLanguageActions = { [weak coordinator = context.coordinator] excerpt in
            coordinator?.parent.allowsLanguageActions(excerpt) == true
        }
        surface.onListeningFocusArrived = { [weak coordinator = context.coordinator] id in
            coordinator?.parent.onListeningFocusArrived(id)
        }
        view.onTextClick = { [weak coordinator = context.coordinator, weak surface] position in
            guard let surface else { return }
            surface.clickedCharacter = position
            if coordinator?.parent.onTextClick(position) == true || surface.selectedMark != nil {
                surface.showActions()
            }
        }
        view.onUserSelection = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onUserSelection(selection)
        }
        view.onUserPhraseSelection = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onUserPhraseSelection(selection)
        }
        surface.onTranslateSelection = { [weak coordinator = context.coordinator] excerpt in
            coordinator?.parent.onTranslateSelection(excerpt)
        }
        surface.onReadingPosition = { [weak coordinator = context.coordinator] position, version, saveForResume in
            coordinator?.parent.onReadingPosition(position, version, saveForResume)
        }
        surface.onTranslateSentence = { [weak coordinator = context.coordinator] excerpt in
            coordinator?.parent.onTranslateSentence(excerpt)
        }
        surface.onSpeakSelection = { [weak coordinator = context.coordinator] excerpt in
            coordinator?.parent.onSpeakSelection(excerpt)
        }
        surface.onCancelMark = { [weak coordinator = context.coordinator] id in
            coordinator?.parent.onCancelMark(id)
        }
        surface.onWordStudy = { [weak coordinator = context.coordinator] kind, excerpt in
            coordinator?.parent.onWordStudy(kind, excerpt)
        }
        view.onOpenFigure = { [weak coordinator = context.coordinator] in coordinator?.parent.onOpenFigure($0) }
        context.coordinator.surface = surface
        return surface
    }

    func updateNSView(_ nativeView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let surface = nativeView as? ReadingSurface, let storage = surface.text.textStorage else { return }
        let scroll = surface.scroll
        let view = surface.text
        surface.isUpdatingText = true
        defer { surface.isUpdatingText = false }
        surface.articleVersion = version
        surface.setWordAction(wordAction)
        surface.setListeningMarks(listeningMarks)
        surface.setInterfaceScale(interfaceScale)

        let newArticle = coordinator.version != version
        let newFont = coordinator.fontSize != fontSize
        let newInline = view.inlineTranslation != inlineTranslation
        let newFigures = coordinator.figures != figures ||
            (!figures.isEmpty && coordinator.figureScale != interfaceScale)
        let reflow = newArticle || newFont || newInline || newFigures
        if reflow {
            surface.resetResizeAnchor()
            let selection = view.originalSelectionRange
            let anchor = newArticle ? nil : view.scrollAnchor(top: scroll.contentView.bounds.minY)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fontSize * 0.31
            style.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Georgia", size: fontSize) ?? .systemFont(ofSize: fontSize),
                .foregroundColor: ReaderPalette.inkNS,
                .paragraphStyle: style
            ]
            view.defaultParagraphStyle = style
            view.applyHighlights(previous: coordinator.marks, current: [])
            view.originalText = bodyText
            view.inlineTranslation = inlineTranslation
            let content = NSMutableAttributedString(string: bodyText, attributes: attributes)
            var blocks: [(offset: Int, content: NSAttributedString, index: Int?)] = []
            view.translationCloseRange = nil
            view.translationDisplayRange = nil
            view.figureDisplayIndices = [:]
            if let inlineTranslation {
                let tone = ReaderPalette.highlight(.referent)
                let translated = NSMutableAttributedString(string: inlineTranslation.displayText, attributes: [
                    .font: NSFont.systemFont(ofSize: max(17, min(32, fontSize * 0.82))),
                    .foregroundColor: tone.ink,
                    .paragraphStyle: style
                ])
                translated.addAttribute(.backgroundColor, value: tone.fill,
                                        range: NSRange(location: 1, length: inlineTranslation.displayLength - 2))
                let close = NSRange(location: inlineTranslation.closeRange.location - inlineTranslation.insertion,
                                    length: inlineTranslation.closeRange.length)
                translated.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: close)
                translated.addAttribute(.toolTip, value: "点击收起这条译文", range: close)
                blocks.append((inlineTranslation.insertion, translated, nil))
            }
            let source = bodyText as NSString
            for figure in figures {
                let offset = figure.placement.offset
                guard offset >= 0, offset <= source.length, Range(NSRange(location: offset, length: 0), in: bodyText) != nil else { continue }
                let block = NSMutableAttributedString(string: offset == source.length && offset != 0 ? "\n\n" : "",
                                                      attributes: attributes)
                let attachmentIndex = block.length
                let attachment = NSTextAttachment()
                if let image = figure.image {
                    let size = NSSize(width: image.width, height: image.height)
                    attachment.attachmentCell = ReaderFigureCell(imageCell: NSImage(cgImage: image, size: size))
                } else {
                    attachment.attachmentCell = ReaderFigureCell(imageCell: NSImage(systemSymbolName: "photo", accessibilityDescription: nil))
                }
                block.append(NSAttributedString(attachment: attachment))
                let caption = figure.placement.inPageGallery ? "本页插图 \(figure.index + 1)" : "插图 \(figure.index + 1)"
                block.append(NSAttributedString(string: "\n" + caption + "\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13 * interfaceScale),
                    .foregroundColor: ReaderPalette.inkNS,
                    .paragraphStyle: style
                ]))
                let captionRange = NSRange(location: attachmentIndex + 2, length: caption.utf16.count)
                block.addAttribute(.link, value: NSNumber(value: figure.index), range: captionRange)
                block.addAttribute(.toolTip, value: "点击放大 · " + caption, range: NSRange(location: attachmentIndex, length: 1))
                blocks.append((offset, block, figure.index))
            }
            blocks = blocks.enumerated().sorted {
                ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset)
            }.map(\.element)
            view.displayMap = ReaderDisplayMap(blocks.map { ($0.offset, $0.content.length) })
            for (block, insertion) in zip(blocks, view.displayMap.insertions) {
                content.insert(block.content, at: insertion.displayRange.location)
                if let index = block.index {
                    block.content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: block.content.length)) { value, range, _ in
                        if value != nil { view.figureDisplayIndices[insertion.displayRange.location + range.location] = index }
                    }
                } else if let inlineTranslation {
                    view.translationDisplayRange = insertion.displayRange
                    let close = inlineTranslation.closeRange
                    view.translationCloseRange = NSRange(location: insertion.displayRange.location + close.location - inlineTranslation.insertion,
                                                         length: close.length)
                }
            }
            storage.setAttributedString(content)
            if newArticle {
                surface.clickedCharacter = nil
                surface.pendingResumeCharacter = nil
                surface.setSelection(nil)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                view.setSelectedRange(view.displayedRange(for: selection))
                if let anchor { view.restore(anchor: anchor, in: scroll) }
            }
            coordinator.version = version
            coordinator.fontSize = fontSize
            coordinator.figures = figures
            coordinator.figureScale = interfaceScale
            surface.needsLayout = true
        }

        var visibleMarks = marks + listeningMarks.map { ReaderMark(range: $0.range, style: .listening) }
        if highlightsSpeech, let range = listeningFocus?.request.range, range.location >= 0, range.length > 0,
           NSMaxRange(range) <= bodyText.utf16.count {
            visibleMarks.append(ReaderMark(range: range, style: .spoken))
        }
        if reflow || coordinator.marks != visibleMarks {
            view.applyHighlights(previous: reflow ? [] : coordinator.marks, current: visibleMarks)
            coordinator.marks = visibleMarks
        }
        if let jump, coordinator.jumpID != jump.id {
            coordinator.jumpID = jump.id
            let displayed = view.displayedRange(for: jump.range)
            if jump.select {
                view.setSelectedRange(displayed)
                surface.setSelection(view.selectionExcerpt())
                surface.showActions()
                view.window?.makeFirstResponder(view)
            }
            if jump.alignToTop {
                surface.pendingResumeCharacter = jump.range.location
            } else if jump.showInline, let range = view.translationDisplayRange {
                view.scrollRangeToVisible(range)
            } else {
                view.scrollRangeToVisible(displayed)
            }
            surface.needsLayout = true
        }
        view.refreshSelectionAppearance(marks: visibleMarks)
        surface.setListeningFocus(listeningFocus, opacity: maskOpacity, reflow: reflow)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReaderTextView
        fileprivate weak var surface: ReadingSurface?
        var version: UUID?
        var fontSize: Double?
        var figures: [ReaderFigure] = []
        var figureScale: CGFloat?
        var marks: [ReaderMark] = []
        var jumpID: UUID?

        init(parent: ReaderTextView) { self.parent = parent }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let index = link as? NSNumber, parent.figures.contains(where: { $0.index == index.intValue }) else {
                return false
            }
            parent.onOpenFigure(index.intValue)
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard surface?.isUpdatingText != true, let view = notification.object as? ClickableTextView else { return }
            let selection = view.selectionExcerpt()
            surface?.setSelection(selection)
            view.refreshSelectionAppearance(marks: marks)
            parent.onSelection(selection)
            if surface?.isTrackingSelection != true, let selection {
                parent.onUserSelection(selection)
            }
        }
    }
}

private final class ReaderLayoutManager: NSLayoutManager {
    var spokenSegments: [NSRange] = []

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !spokenSegments.isEmpty, let container = textContainers.first else { return }

        // Draw after the native selection background so it cannot hide the spoken sentence.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        ReaderPalette.highlight(.spoken).fill.setFill()
        for segment in spokenSegments {
            let glyphs = glyphRange(forCharacterRange: segment, actualCharacterRange: nil)
            let visibleGlyphs = NSIntersectionRange(glyphsToShow, glyphs)
            guard visibleGlyphs.length > 0 else { continue }
            enumerateEnclosingRects(forGlyphRange: visibleGlyphs,
                                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                rect.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
    }
}

private final class ReadingSurface: NSView {
    let scroll: NSScrollView
    let text: ClickableTextView
    var onTranslateSelection: ((TextExcerpt) -> Void)?
    var allowsLanguageActions: ((TextExcerpt) -> Bool)?
    var onReadingPosition: ((Int, UUID, Bool) -> Void)?
    var onTranslateSentence: ((TextExcerpt) -> Void)?
    var onSpeakSelection: ((TextExcerpt) -> Void)?
    var onCancelMark: ((UUID) -> Void)?
    var onWordStudy: ((StudyKind, TextExcerpt) -> Void)?
    var onListeningFocusArrived: ((UUID) -> Void)?
    var isUpdatingText = false
    var articleVersion: UUID?
    var pendingResumeCharacter: Int?

    private var selection: TextExcerpt?
    private var listeningMarks: [TextListeningMark] = []
    var clickedCharacter: Int?
    var selectedMark: TextListeningMark? {
        TextListeningMark.matching(listeningMarks, selection: selection?.range, click: clickedCharacter)
    }
    private var wordAction: SelectionActions.WordAction?
    private var areActionsDismissed = false
    private(set) var isTrackingSelection = false
    private var prefersStart = false
    private var resizeAnchor: ClickableTextView.ScrollAnchor?
    private var isResizingViewport = false
    private var lastScrollY: CGFloat = 0
    private var reportPending = false
    private var pendingUserScrollVersion: UUID?
    private var interfaceScale: CGFloat = 1
    private var actionsScale: CGFloat = 1
    private var showsLanguageActions = false
    private var shownMark: TextListeningMark?
    private lazy var actions = NSHostingView(rootView: actionView())
    private let shade = ListeningShadeView()
    private var listeningFocus: ListeningFocus?
    private var focusBlock: CGRect?
    private var arrivalWindow: CGRect?
    private var focusTask: Task<Void, Never>?
    private var needsFocusLayout = false

    override var isFlipped: Bool { true }

    init(scroll: NSScrollView, text: ClickableTextView) {
        self.scroll = scroll
        self.text = text
        super.init(frame: .zero)
        addSubview(scroll)
        addSubview(shade, positioned: .above, relativeTo: scroll)
        actions.sizingOptions = []
        actions.isHidden = true
        addSubview(actions, positioned: .above, relativeTo: scroll)

        text.onSelectionBegan = { [weak self] in self?.beginSelection() }
        text.onSelectionEnded = { [weak self] prefersStart in self?.finishSelection(prefersStart: prefersStart) }
        text.onCancelActions = { [weak self] in self?.dismissActions() ?? false }
        NotificationCenter.default.addObserver(self, selector: #selector(viewportDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(userDidScroll(_:)),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if scroll.frame != bounds {
            let widthChanged = scroll.frame.width != bounds.width
            if widthChanged, resizeAnchor == nil {
                resizeAnchor = text.scrollAnchor(top: scroll.contentView.bounds.minY)
            }
            isResizingViewport = true
            scroll.frame = bounds
            if widthChanged, let resizeAnchor { text.restore(anchor: resizeAnchor, in: scroll) }
            isResizingViewport = false
            needsFocusLayout = true
        }
        if let character = pendingResumeCharacter, bounds.width > 0, bounds.height > 0 {
            pendingResumeCharacter = nil
            isResizingViewport = true
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
            text.sizeToFit()
            text.restore(anchor: .init(character: character, lineOffset: 0), in: scroll)
            isResizingViewport = false
            resetResizeAnchor()
        }
        if needsFocusLayout {
            needsFocusLayout = false
            alignListeningFocus()
        }
        updateShade()
        let viewport = convert(scroll.contentView.bounds, from: scroll.contentView)
        let excerpt = selection ?? wordAction?.excerpt
        let mark = selectedMark
        let language = excerpt.map { anchor in
            allowsLanguageActions?(anchor) == true && (text.inlineTranslation.map {
                NSIntersectionRange(anchor.range, $0.sentence).length == 0
            } ?? true)
        } ?? false
        guard !areActionsDismissed, !isTrackingSelection,
              let anchor = language ? excerpt?.range : mark?.range else {
            actions.isHidden = true
            return
        }
        let lines = text.visibleSelectionLines(for: text.displayedRange(for: anchor))
            .map { convert($0, from: text).intersection(viewport) }
            .filter { !$0.isEmpty }
        let forWord = selection == nil && wordAction != nil
        let baseSize = SelectionActionPlacement.size(forWord: forWord, hasLanguageActions: language,
                                                     hasMark: mark != nil, scale: 1)
        let scale = min(interfaceScale, max(0, (viewport.width - 16) / baseSize.width))
        let size = SelectionActionPlacement.size(forWord: forWord, hasLanguageActions: language,
                                                 hasMark: mark != nil, scale: scale)
        guard scale > 0 else {
            actions.isHidden = true
            return
        }
        guard let frame = SelectionActionPlacement.frame(near: lines, in: viewport,
                                                         prefersStart: selection != nil && prefersStart, size: size) else {
            actions.isHidden = true
            return
        }
        if actionsScale != scale || showsLanguageActions != language || shownMark != mark {
            actionsScale = scale
            showsLanguageActions = language
            shownMark = mark
            actions.rootView = actionView()
        }
        actions.frame = frame
        actions.isHidden = false
    }

    func setListeningFocus(_ focus: ListeningFocus?, opacity: Double, reflow: Bool) {
        if shade.opacity != opacity {
            shade.opacity = opacity
            updateShade()
        }
        guard focus != listeningFocus || (focus != nil && reflow) else { return }
        focusTask?.cancel()
        focusTask = nil
        listeningFocus = focus
        if focus != nil { dismissActions() }
        else {
            focusBlock = nil
            arrivalWindow = nil
            updateShade()
        }
        needsFocusLayout = true
        needsLayout = true
    }

    private func alignListeningFocus() {
        let clip = scroll.contentView
        let viewport = clip.bounds
        guard viewport.width > 0, viewport.height > 0 else { return }
        focusTask?.cancel()
        focusTask = nil
        isResizingViewport = true
        defer { isResizingViewport = false }

        // The extra space lets the first and last paragraphs reach the same reading position.
        let inset = listeningFocus == nil ? 16 : max(16, viewport.height / 2)
        let previousInset = text.textContainerInset.height
        if inset != previousInset {
            text.textContainerInset = NSSize(width: text.textContainerInset.width, height: inset)
        }
        guard listeningFocus != nil || inset != previousInset else { return }
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        text.sizeToFit()
        if inset != previousInset {
            scroll(toY: max(0, viewport.minY + inset - previousInset))
        }
        guard let focus = listeningFocus else { return }
        guard let sentence = text.lineBlock(for: focus.request.range) else {
            DispatchQueue.main.async { [weak self] in self?.onListeningFocusArrived?(focus.request.id) }
            return
        }
        let paragraph = text.lineBlock(for: focus.paragraph)?.rect ?? sentence.rect
        let target = paragraph.height > viewport.height * 0.84 ? sentence.rect : paragraph
        focusBlock = paragraph.insetBy(dx: 0, dy: -4)
        let focusCenter = target.height > viewport.height * 0.84 ? target.minY + sentence.lineHeight / 2 : target.midY
        let destination = clip.constrainBoundsRect(CGRect(x: viewport.minX, y: focusCenter - viewport.height / 2,
                                                         width: viewport.width, height: viewport.height)).minY
        let distance = abs(destination - clip.bounds.minY)
        let step = min(sentence.lineHeight, max(sentence.lineHeight * 0.17, distance / 120))
        let openingHeight = min(viewport.height, target.height + 8)
        arrivalWindow = CGRect(x: 0, y: (viewport.height - openingHeight) / 2,
                               width: viewport.width, height: openingHeight)

        focusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.listeningFocus == focus else { return }
                let remaining = destination - self.scroll.contentView.bounds.minY
                if abs(remaining) <= step {
                    self.scroll(toY: destination)
                    self.arrivalWindow = nil
                    self.updateShade()
                    self.onListeningFocusArrived?(focus.request.id)
                    return
                }
                let next = self.scroll.contentView.bounds.minY + (remaining > 0 ? step : -step)
                self.scroll(toY: next)
                self.updateShade()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func scroll(toY y: CGFloat) {
        let clip = scroll.contentView
        var target = clip.bounds
        target.origin.y = y
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func updateShade() {
        shade.isHidden = listeningFocus == nil || shade.opacity <= 0
        guard !shade.isHidden else { return }
        shade.frame = convert(scroll.contentView.bounds, from: scroll.contentView)
        guard let block = focusBlock else { shade.opening = .null; return }
        let visible = shade.convert(block, from: text)
        let band = CGRect(x: 0, y: visible.minY, width: shade.bounds.width, height: visible.height)
        shade.opening = band.intersection(arrivalWindow ?? shade.bounds)
    }

    func resetResizeAnchor() {
        resizeAnchor = nil
    }

    func setInterfaceScale(_ scale: CGFloat) {
        guard interfaceScale != scale else { return }
        interfaceScale = scale
        needsLayout = true
    }

    func setWordAction(_ action: SelectionActions.WordAction?) {
        guard wordAction != action else { return }
        wordAction = action
        actions.rootView = actionView()
        needsLayout = true
    }

    func setListeningMarks(_ marks: [TextListeningMark]) {
        guard listeningMarks != marks else { return }
        listeningMarks = marks
        needsLayout = true
    }

    func showActions() {
        areActionsDismissed = false
        needsLayout = true
    }

    @discardableResult
    private func dismissActions() -> Bool {
        let wasVisible = !actions.isHidden
        areActionsDismissed = true
        actions.isHidden = true
        return wasVisible
    }

    private func actionView() -> SelectionActions {
        let cancelMark: (() -> Void)? = shownMark.map { mark in
            { [weak self] in
                guard let self, self.selectedMark == mark else { return }
                self.onCancelMark?(mark.id)
            }
        }
        return SelectionActions(wordAction: selection == nil ? wordAction : nil,
                                hasLanguageActions: showsLanguageActions, cancelMark: cancelMark, scale: actionsScale,
                         translation: { [weak self] in
                             guard let self, let selection = self.selection,
                                   self.text.originalSelectionRange == selection.range else { return }
                             self.onTranslateSelection?(selection)
                         },
                         speak: { [weak self] in
                             guard let self, let selection = self.selection else { return }
                             self.onSpeakSelection?(selection)
                         },
                         translateSentence: { [weak self] in
                             guard let self, let word = self.wordAction else { return }
                             self.onTranslateSentence?(word.excerpt)
                         },
                         wordStudy: { [weak self] kind in
                             guard let self, let word = self.wordAction else { return }
                             self.onWordStudy?(kind, word.excerpt)
                         }, close: { [weak self] in self?.dismissActions() })
    }

    func setSelection(_ next: TextExcerpt?) {
        guard selection?.range != next?.range else { return }
        if !isTrackingSelection {
            prefersStart = if let previous = selection?.range, let current = next?.range {
                current.location != previous.location && NSMaxRange(current) == NSMaxRange(previous)
            } else {
                false
            }
        }
        let changedMode = (selection == nil) != (next == nil)
        selection = next
        if changedMode && wordAction != nil { actions.rootView = actionView() }
        if next != nil, !isTrackingSelection { showActions() }
        if next == nil { dismissActions() }
        needsLayout = true
    }

    @objc private func viewportDidScroll(_ notification: Notification) {
        let y = scroll.contentView.bounds.minY
        let moved = y != lastScrollY
        lastScrollY = y
        if moved { updateShade() }
        guard moved, !isResizingViewport else { return }
        if !isUpdatingText {
            resetResizeAnchor()
            if !isTrackingSelection { dismissActions() }
        }
        reportReadingPosition()
    }

    @objc private func userDidScroll(_ notification: Notification) {
        guard !isUpdatingText, !isResizingViewport else { return }
        pendingUserScrollVersion = articleVersion
        reportReadingPosition()
    }

    private func reportReadingPosition() {
        if !reportPending, let version = articleVersion {
            reportPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportPending = false
                let saveForResume = self.pendingUserScrollVersion == version
                if saveForResume { self.pendingUserScrollVersion = nil }
                guard self.articleVersion == version else { return }
                let position = self.text.scrollAnchor(top: self.scroll.contentView.bounds.minY)?.character ?? 0
                self.onReadingPosition?(position, version, saveForResume)
            }
        }
    }

    private func beginSelection() {
        clickedCharacter = nil
        isTrackingSelection = true
        dismissActions()
    }

    private func finishSelection(prefersStart: Bool) {
        setSelection(text.selectionExcerpt())
        isTrackingSelection = false
        self.prefersStart = prefersStart
        if selection != nil { showActions() }
    }
}

private final class ListeningShadeView: NSView {
    var opacity: Double = 0 {
        didSet { if oldValue != opacity { needsDisplay = true } }
    }

    var opening: CGRect = .null {
        didSet { if oldValue != opening { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(opacity).setFill()
        let opening = bounds.intersection(opening)
        if opening.isNull || opening.isEmpty {
            dirtyRect.fill()
        } else {
            let upper = NSRect(x: 0, y: 0, width: bounds.width, height: opening.minY).intersection(dirtyRect)
            let lower = NSRect(x: 0, y: opening.maxY, width: bounds.width,
                               height: bounds.maxY - opening.maxY).intersection(dirtyRect)
            if !upper.isEmpty { upper.fill() }
            if !lower.isEmpty { lower.fill() }
        }
    }
}

private final class ReaderFigureCell: NSTextAttachmentCell {
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let original = cellSize()
        let width = max(1, min(440, lineFrag.width - 2 * textContainer.lineFragmentPadding))
        let scale = min(1, width / max(1, original.width), 280 / max(1, original.height))
        return NSRect(x: 0, y: 0, width: original.width * scale, height: original.height * scale)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private final class ClickableTextView: NSTextView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
        needsDisplay = true
    }

    var originalText = ""
    var inlineTranslation: InlineTranslation?
    var displayMap = ReaderDisplayMap([])
    var translationCloseRange: NSRange?
    var translationDisplayRange: NSRange?
    var figureDisplayIndices: [Int: Int] = [:]
    var onOpenFigure: ((Int) -> Void)?

    var onTextClick: ((Int) -> Void)?
    var onUserSelection: ((TextExcerpt) -> Void)?
    var onUserPhraseSelection: ((TextExcerpt) -> Void)?
    var onCloseInline: (() -> Void)?
    var onSelectionBegan: (() -> Void)?
    var onSelectionEnded: ((_ prefersStart: Bool) -> Void)?
    var onCancelActions: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if onCancelActions?() != true { super.cancelOperation(sender) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, let index = textIndex(at: point) {
            if let close = translationCloseRange, NSLocationInRange(index, close) {
                onCloseInline?()
                return
            }
            if let figure = figureDisplayIndices[index] {
                onOpenFigure?(figure)
                return
            }
        }
        onSelectionBegan?()
        super.mouseDown(with: event)
        let range = selectedRange()
        if range.length > 0 {
            let initial = characterIndexForInsertion(at: point)
            let beganNearEnd = initial != NSNotFound
                && abs(initial - NSMaxRange(range)) < abs(initial - range.location)
            onSelectionEnded?(event.modifierFlags.contains(.shift) ? !beganNearEnd : beganNearEnd)
            guard let excerpt = selectionExcerpt() else { return }
            onUserSelection?(excerpt)
            if event.clickCount == 1,
               event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty {
                onUserPhraseSelection?(excerpt)
            }
            return
        }
        onSelectionEnded?(false)
        guard event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
              let index = textIndex(at: point) else { return }
        if let original = displayMap.sourceCharacter(at: index) { onTextClick?(original) }
    }

    private func textIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard line.contains(local), local.x >= rect.minX, local.x < rect.maxX else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    var originalSelectionRange: NSRange {
        displayMap.sourceRange(for: selectedRange())
    }

    func displayedRange(for range: NSRange) -> NSRange {
        displayMap.displayedRange(for: range)
    }

    override func copy(_ sender: Any?) {
        guard !figureDisplayIndices.isEmpty else { super.copy(sender); return }
        let range = originalSelectionRange
        guard range.length > 0, NSMaxRange(range) <= originalText.utf16.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString((originalText as NSString).substring(with: range), forType: .string)
    }

    func selectionExcerpt() -> TextExcerpt? {
        let range = originalSelectionRange
        let body = originalText as NSString
        guard range.length > 0, NSMaxRange(range) <= body.length else { return nil }
        let text = body.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : TextExcerpt(text: text, range: range, context: "")
    }

    func visibleSelectionLines(for characters: NSRange) -> [CGRect] {
        guard let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let selectedGlyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        let glyphs = NSIntersectionRange(visibleGlyphs, selectedGlyphs)
        guard glyphs.length > 0 else { return [] }
        var lines: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, line, _ in
            let range = NSIntersectionRange(glyphs, line)
            let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
                .intersection(used)
            if !rect.isEmpty { lines.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
        }
        return lines
    }

    func lineBlock(for range: NSRange) -> (rect: CGRect, lineHeight: CGFloat)? {
        guard let layoutManager, range.length > 0,
              NSMaxRange(range) <= originalText.utf16.count else { return nil }
        let characters = displayedRange(for: range)
        layoutManager.ensureLayout(forCharacterRange: characters)
        let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let rect = first.union(last).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (rect, max(1, first.height))
    }

    func applyHighlights(previous: [ReaderMark], current: [ReaderMark]) {
        guard let layoutManager = layoutManager as? ReaderLayoutManager else { return }
        layoutManager.spokenSegments = []
        for mark in previous {
            for range in displayMap.displayedSegments(for: mark.range) {
                if mark.style == .listening {
                    layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
                    layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
                } else {
                    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                    layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                }
            }
        }
        for mark in current {
            let tone = ReaderPalette.highlight(mark.style)
            for range in displayMap.displayedSegments(for: mark.range) {
                if mark.style == .spoken {
                    layoutManager.spokenSegments.append(range)
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: tone.ink, forCharacterRange: range)
                } else if mark.style == .listening {
                    layoutManager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: tone.ink],
                                                         forCharacterRange: range)
                } else {
                    layoutManager.addTemporaryAttributes([.backgroundColor: tone.fill, .foregroundColor: tone.ink],
                                                         forCharacterRange: range)
                }
            }
        }
    }

    func refreshSelectionAppearance(marks: [ReaderMark]) {
        let range = originalSelectionRange
        let overlaps = marks.contains { $0.style != .word && $0.style != .hint && $0.style != .spoken && $0.style != .listening
            && NSIntersectionRange($0.range, range).length > 0 }
        let background = overlaps ? NSColor.clear : NSColor.selectedTextBackgroundColor
        if (selectedTextAttributes[.backgroundColor] as? NSColor) != background {
            selectedTextAttributes = [.backgroundColor: background]
        }
    }

    struct ScrollAnchor {
        let character: Int
        let lineOffset: CGFloat
    }

    func scrollAnchor(top: CGFloat) -> ScrollAnchor? {
        guard let layoutManager, let textContainer, top > textContainerOrigin.y else { return nil }
        let localY = max(0, top - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 2, y: localY), in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let original = displayMap.sourceBoundary(at: index)
        return ScrollAnchor(character: original, lineOffset: localY - line.minY)
    }

    func restore(anchor: ScrollAnchor, in scroll: NSScrollView) {
        let index = displayedRange(for: NSRange(location: anchor.character, length: 0)).location
        guard let layoutManager, index < (textStorage?.length ?? 0) else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        guard glyph < layoutManager.numberOfGlyphs else { return }
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let point = NSPoint(x: 0, y: max(0, line.minY + textContainerOrigin.y + anchor.lineOffset))
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(
            NSRect(origin: point, size: scroll.contentView.bounds.size)
        ).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
