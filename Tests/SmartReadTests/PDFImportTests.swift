import CoreText
import PDFKit
import XCTest
@testable import SmartRead

final class PDFImportTests: XCTestCase {
    func testPageRangesAndBoxOrder() throws {
        var draft = PDFImportDraft()
        let pages = try PDFImportDraft.pages(in: "4、2–3, 2", count: 8)
        XCTAssertEqual(pages, [1, 2, 3])
        for input in ["0", "9", "8–2", "1,,2", ""] {
            XCTAssertThrowsError(try PDFImportDraft.pages(in: input, count: 8))
        }
        _ = draft.addPages(pages)
        let first = draft.addBox(CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.3), page: 1)
        let second = draft.addBox(CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.3), page: 1)
        XCTAssertEqual(draft.parts.map(\.page), [1, 2, 3, 1])
        XCTAssertNil(draft.addPages([1]))
        XCTAssertEqual(draft.pageSummary, "2–4")
        XCTAssertFalse(draft.readyToImport)
        draft.update(first) { $0.text = "The passage starts" }
        draft.update(second) { $0.text = "on the right."; $0.joinsPrevious = true }
        draft.move(second, to: 1)
        XCTAssertEqual(draft.body, "The passage starts on the right.")
        draft.remove(first)
        XCTAssertFalse(draft.parts[0].joinsPrevious)
        XCTAssertEqual(draft.body, "on the right.")
    }

    func testScannedBodyWithSelectableFooterCanBeCorrectedInSelectionOrder() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appending(path: "Scan.pdf")
        let raster = try XCTUnwrap(CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        raster.setFillColor(CGColor(gray: 1, alpha: 1))
        raster.fill(bounds)
        func draw(_ text: String, at y: CGFloat, on context: CGContext) {
            let text = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 27),
                                                                      .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        draw("The first sentence.", at: 600, on: raster)
        draw("The second sentence.", at: 200, on: raster)
        let pdfContext = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &bounds, nil))
        pdfContext.beginPDFPage(nil)
        pdfContext.draw(try XCTUnwrap(raster.makeImage()), in: bounds)
        draw("Page 1", at: 12, on: pdfContext)
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        let library = root.appending(path: "Books")
        let store = PDFBookStore(root: library)
        let book = try await store.importBook(pdf)
        let first = try await store.article(for: book, at: 0, englishOnly: false)
        let page = try XCTUnwrap(first?.pdfPage)
        XCTAssertTrue(page.usedOCR)
        XCTAssertTrue(first?.body.contains("first sentence") == true)
        let boxes = [CGRect(x: 0.04, y: 0.65, width: 0.91, height: 0.18),
                     CGRect(x: 0.04, y: 0.15, width: 0.91, height: 0.18)]
        let corrected = try await store.correct(page, at: 0, boxes: boxes)
        XCTAssertEqual(corrected.body, "The second sentence.\n\nThe first sentence.")
        let reopened = PDFBookStore(root: library)
        let saved = try await reopened.savedBoxes(for: book, at: 0)
        XCTAssertEqual(saved, boxes)
        let chapter = PDFChapter(firstPage: 0, lastPage: 0, heading: nil)
        let joined = try await reopened.chapterArticle(for: book, chapter: chapter, englishOnly: false)
        XCTAssertTrue(joined.body.hasPrefix("The second sentence."))
        let location = try XCTUnwrap(joined.pdfPage)
        let restored = try await reopened.correct(location, at: 0, boxes: Array(boxes.reversed()))
        XCTAssertNotNil(restored.pdfPage?.chapter)
        XCTAssertTrue(restored.body.hasPrefix("The first sentence."))
    }

    func testEmbeddedTextSelectionWithRotatedPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appending(path: "Selectable.pdf")
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let contents = [("Upper native words", CGPoint(x: 40, y: 435)),
                        ("Lower native words", CGPoint(x: 40, y: 100))]
        for (text, point) in contents {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()

        let doc = try XCTUnwrap(PDFDocument(data: data as Data))
        try XCTUnwrap(doc.page(at: 0)).rotation = 90
        XCTAssertTrue(doc.write(to: pdf))
        let document = try await PDFImportDocument.open(pdf)
        let image = try await document.preview(page: 0)
        XCTAssertGreaterThan(image.width, image.height)
        let part = PDFImportPart(page: 0, box: CGRect(x: 0.80, y: 0.05, width: 0.18, height: 0.52))
        let result = try await document.extract(part)
        XCTAssertEqual(result.text, "Upper native words")
        XCTAssertFalse(result.usedOCR)
    }

    @MainActor
    func testTextbookPageBoxesOCRAndHistory() async throws {
        guard let path = ProcessInfo.processInfo.environment["SMARTREAD_TEST_PDF"] else {
            throw XCTSkip("Set SMARTREAD_TEST_PDF to the sample textbook")
        }
        let document = try await PDFImportDocument.open(URL(fileURLWithPath: path))
        let regionBounds: [(Int, Int, Int, Int)] = [
            (175, 201, 491, 391), (177, 403, 487, 493), (293, 493, 491, 699),
            (513, 201, 645, 291), (512, 292, 840, 431),
            (512, 447, 829, 606), (514, 625, 831, 701)
        ]
        var draft = PDFImportDraft()
        for (index, (left, top, right, bottom)) in regionBounds.enumerated() {
            let rect = CGRect(x: CGFloat(left) / 944, y: CGFloat(top) / 1230,
                              width: CGFloat(right - left) / 944, height: CGFloat(bottom - top) / 1230)
            let part = PDFImportPart(page: 110, box: rect)
            let result = try await document.extract(part)
            XCTAssertTrue(result.usedOCR)
            XCTAssertFalse(result.text.isEmpty, "Empty crop \(index + 1)")
            let id = draft.addBox(rect, page: 110)
            draft.update(id) { $0.text = result.text; $0.joinsPrevious = [2, 4].contains(index) }
        }
        XCTAssertTrue(draft.readyToImport)
        let body = draft.body
        let parts = ["Tommy was born in Colombo", "When he was six", "Looking back", "third culture kid", "Sometimes"]
        var position = body.startIndex
        for prefix in parts {
            let match = try XCTUnwrap(body.range(of: prefix, options: .caseInsensitive, range: position..<body.endIndex))
            position = match.upperBound
        }
        XCTAssertTrue(body.contains("United States was different"))
        XCTAssertTrue(body.contains("streets were quieter"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("Read the article"))
        XCTAssertFalse(body.localizedCaseInsensitiveContains("Kurunegala"))
        XCTAssertEqual(draft.pageSummary, "111")

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        let learning = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(store: store, learningStore: learning)
        try reader.importText(body, title: "The Story of a Third Culture Kid")
        try reader.importText("Another article.", title: "Next article")
        let reloaded = ReaderModel(store: store, learningStore: learning)
        let history = try XCTUnwrap(reloaded.history.first)
        try reloaded.openHistoryArticle(history.id)
        XCTAssertEqual(reloaded.article.body, body)
    }
}
