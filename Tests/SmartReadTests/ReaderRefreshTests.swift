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
