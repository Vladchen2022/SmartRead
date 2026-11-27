import SwiftUI
import XCTest
@testable import SmartRead

final class ReaderRefreshTests: XCTestCase {
    @MainActor
    func testImportUpdatesTheOpenReadingSurfaceAtTheSameFontSize() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root.appending(path: "Library"))
        let reader = ReaderModel(store: store, learningStore: LearningRecordStore(projectRoot: root))
        let oldBody = "The original reading is already on screen."
        let newBody = "The newly recognized PDF text is ready to read."
        try reader.importText(oldBody, title: "Original article")

        let video = VideoStudyModel(repository: try LearningRepository(inMemory: true))
        let view = ReaderWindow(reader: reader, speech: ReaderSpeech(), audio: AudioStudyModel(), video: video,
                                mode: .constant(.text), sheet: .constant(nil), fontSize: .constant(29),
                                choosesAudioFile: .constant(false), openPDF: { _ in })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -1400, y: 0, width: 1150, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await waitForArticle(oldBody, in: host)
        let oldTextView = try XCTUnwrap(renderedArticle(in: host))

        try reader.importText(newBody, title: "Recognized PDF")

        try await waitForArticle(newBody, in: host)
        XCTAssertFalse(renderedArticle(in: host) === oldTextView)
        XCTAssertEqual(reader.history.first?.article.body, oldBody)
        XCTAssertEqual(try store.load().current?.body, newBody)
    }

    @MainActor
    func testSpacePreviewsTheSelectionOnlyOutsideListeningMode() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "SmartReadTests.PreviewSpace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let reader = ReaderModel(defaults: defaults, store: ArticleStore(root: root),
                                 learningStore: LearningRecordStore(projectRoot: root))
        let speech = ReaderSpeech(defaults: defaults)
        let body = "She paused. Then she spoke."
        try reader.importText(body, title: "Preview")
        let video = VideoStudyModel(repository: try LearningRepository(inMemory: true))
        let view = ReaderWindow(reader: reader, speech: speech, audio: AudioStudyModel(), video: video,
                                mode: .constant(.text), sheet: .constant(nil), fontSize: .constant(29),
                                choosesAudioFile: .constant(false), openPDF: { _ in })
        let host = NSHostingView(rootView: view)
        let window = ReaderTestWindow(contentRect: NSRect(x: -1400, y: 0, width: 1150, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: host.frame)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        defer { speech.stop(); window.close() }
        host.layoutSubtreeIfNeeded()
        try await waitForArticle(body, in: host)
        let text = try XCTUnwrap(renderedArticle(in: host))
        let plan = reader.articleForListening(fromHere: false)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: " ", charactersIgnoringModifiers: " ",
                                                 isARepeat: false, keyCode: 49))
        text.setSelectedRange(plan.sentences[1].range)
        let monitor = try XCTUnwrap(readingShortcuts(in: host))
        let otherControl = NSButton(title: "Toolbar control", target: nil, action: nil)
        container.addSubview(otherControl)
        XCTAssertTrue(window.makeFirstResponder(otherControl))
        XCTAssertTrue(window.firstResponder === otherControl)

        XCTAssertNil(monitor.handleKeyDown(space))
        let startDeadline = ContinuousClock.now + .seconds(3)
        while speech.phase != .playing, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(speech.phase, .playing)
        XCTAssertTrue(speech.isPreviewing)
        XCTAssertNil(speech.focusRequest)
        XCTAssertEqual(text.selectedRange(), plan.sentences[1].range)
        let finishDeadline = ContinuousClock.now + .seconds(5)
        while speech.isPreviewing, ContinuousClock.now < finishDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(speech.phase, .ready)
        XCTAssertFalse(speech.isPreviewing)

        let editor = NSTextView()
        container.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotNil(monitor.handleKeyDown(space))
        XCTAssertFalse(speech.isPreviewing)

        XCTAssertTrue(window.makeFirstResponder(otherControl))
        speech.start(plan.sentences, at: 0)
        XCTAssertNotNil(monitor.handleKeyDown(space))
        XCTAssertFalse(speech.isPreviewing)
        XCTAssertEqual(speech.current?.range, plan.sentences[0].range)
    }

    private final class ReaderTestWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @MainActor
    private func readingShortcuts(in view: NSView) -> PlaybackShortcutMonitor.MonitorView? {
        if let view = view as? PlaybackShortcutMonitor.MonitorView { return view }
        for child in view.subviews {
            if let monitor = readingShortcuts(in: child) { return monitor }
        }
        return nil
    }

    @MainActor
    private func waitForArticle(_ expected: String, in view: NSView) async throws {
        let timeout = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < timeout {
            if renderedArticle(in: view)?.string == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(renderedArticle(in: view)?.string, expected)
    }

    @MainActor
    private func renderedArticle(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.accessibilityLabel() == "文章正文" { return text }
        for child in view.subviews {
            if let result = renderedArticle(in: child) { return result }
        }
        return nil
    }
}
