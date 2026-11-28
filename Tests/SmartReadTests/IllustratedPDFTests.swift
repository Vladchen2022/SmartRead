import CoreGraphics
import CoreText
import PDFKit
import SmartReadSync
import XCTest
@testable import SmartRead

final class IllustratedPDFTests: XCTestCase {
    @MainActor
    func testIllustratedPagesAndSourceRoundTripThroughSharedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("Painting.pdf")
        try makePDF(at: file)
        let first = ReaderModel(defaults: defaults, store: ArticleStore(root: root.appendingPathComponent("First")))
        try await first.importPDFBook(file)
        let original = first.article
        let originalKey = first.questionMaterialID
        await first.setPDFIllustrated(true)
        XCTAssertEqual(first.article.body, original.body)
        XCTAssertEqual(first.questionMaterialID, originalKey)
        let firstPage = try XCTUnwrap(first.article.pdfPage?.illustrated)
        XCTAssertEqual(firstPage.pageCount, 3)
        XCTAssertEqual(firstPage.figures.count, 1)
        let figure = try XCTUnwrap(firstPage.figures.first)
        XCTAssertEqual(figure.offset, (first.article.body as NSString).range(of: "Look at the light.").location)
        XCTAssertFalse(figure.inPageGallery)
        let thumbnail = try await first.pdfFigurePreview(try XCTUnwrap(first.article.pdfPage), figure: figure, longEdge: 600)
        XCTAssertEqual(thumbnail.width, 320, accuracy: 2)

        await first.connectTextSync(to: folder)
        XCTAssertNil(first.textSyncIssue)
        let phone = ReadingSyncStore(root: root.appendingPathComponent("Phone"))
        try phone.connect(to: folder)
        await phone.sync()
        let illustrated = try XCTUnwrap(phone.materials.first(where: { $0.illustratedPDF != nil }))
        let bookID = try XCTUnwrap(illustrated.bookID)
        XCTAssertEqual(illustrated.illustratedPDF, firstPage)
        let copy = root.appendingPathComponent("MobileCache/book.pdf")
        try await phone.downloadPDFAsset(bookID: bookID, to: copy)
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: copy))
        let pdfDocument = try XCTUnwrap(PDFDocument(url: copy))
        let mobilePage = try XCTUnwrap(pdfDocument.page(at: 0))
        let mobileLayout = try ReadingPDFLayout.illustratedPage(mobilePage, englishOnly: false)
        let rebuilt = try mobileLayout.material(title: illustrated.title, bookID: bookID,
            pageIndex: 0, pageCount: pdfDocument.pageCount, englishOnly: false)
        XCTAssertEqual(rebuilt.id, illustrated.id)
        XCTAssertEqual(rebuilt.illustratedPDF, illustrated.illustratedPDF)
        let page = try XCTUnwrap(mobilePage.pageRef)
        let mobileImage = try ReadingPDFPageRaster(page: page, longEdge: 600).image(in: figure.rect)
        XCTAssertEqual(mobileImage.width, thumbnail.width)
        XCTAssertEqual(mobileImage.height, thumbnail.height)

        let anchor = try XCTUnwrap(ReadingAnchor.sentences(in: illustrated.body).last)
        try phone.record([.mark(material: illustrated.id, anchor, true)])
        try phone.recordReadingPosition(material: illustrated.id, progress: .init(offset: anchor.offset, completed: false))
        await phone.sync()
        await first.syncTextLibrary()
        XCTAssertEqual(first.textListeningMarks.map(\.range), [NSRange(location: anchor.offset, length: anchor.length)])
        XCTAssertEqual(first.textSync.progress(for: illustrated.id)?.offset, anchor.offset)

        await first.turnPDFPage(1)
        XCTAssertTrue(first.article.body.isEmpty)
        XCTAssertEqual(first.article.pdfPage?.illustrated?.figures.count, 2)
        try await waitForSync(first)
        await phone.sync()
        let imageOnly = try XCTUnwrap(phone.materials.first { $0.page == 2 })
        XCTAssertEqual(imageOnly.illustratedPDF?.figures.count, 2)
        XCTAssertEqual(phone.progress(for: imageOnly.id)?.offset, 0)

        let otherStore = ArticleStore(root: root.appendingPathComponent("Second"))
        let other = ReaderModel(defaults: defaults, store: otherStore)
        await other.connectTextSync(to: folder)
        XCTAssertEqual(other.remoteReadingMaterial?.page, 2)
        other.openRemoteReadingMaterial()
        XCTAssertEqual(other.article.pdfPage?.index, 1)
        await other.turnPDFPage(1)
        XCTAssertTrue(other.article.body.contains("The last page."))
        XCTAssertEqual(other.article.pdfPage?.index, 2)
        XCTAssertEqual(other.article.pdfPage?.illustrated?.figures.count, 0)
        let assets = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("SmartRead-v1/PDFAssets").path)
        XCTAssertEqual(assets, [bookID + ".pdf"])
    }

    func testForumPDFRepresentativePages() async throws {
        guard let file = ProcessInfo.processInfo.environment["SMARTREAD_TEST_ILLUSTRATED_PDF"] else {
            throw XCTSkip("The illustrated forum PDF is an optional local fixture.")
        }
        let document = try await PDFImportDocument.open(URL(fileURLWithPath: file))
        for (number, firstTextAfterImage) in [(98, "I guess I should have said"), (132, "Glad you all like this one!")] {
            let page = try await document.illustratedBookPage(at: number - 1, englishOnly: false)
            let expected = (page.text as NSString).range(of: firstTextAfterImage)
            XCTAssertFalse(page.text.contains("\t"))
            XCTAssertNotEqual(expected.location, NSNotFound)
            XCTAssertEqual(page.figures?.count, 1)
            XCTAssertEqual(page.figures?.first?.offset, expected.location, "PDF page \(number)")
            XCTAssertEqual(page.figures?.first?.inPageGallery, false)
        }
        let pure = try await document.illustratedBookPage(at: 205, englishOnly: true)
        XCTAssertTrue(pure.text.isEmpty)
        XCTAssertEqual(pure.figures?.count, 2)
        if let pictures = pure.figures, pictures.count == 2 {
            XCTAssertLessThan(pictures[0].rect.minY, pictures[1].rect.minY)
        }
        let forum = try await document.illustratedBookPage(at: 419, englishOnly: false)
        XCTAssertEqual(forum.figures?.count, 0)
        let cover = try await document.illustratedBookPage(at: 0, englishOnly: false)
        XCTAssertEqual(cover.figures?.count, 1)
    }

    func testDisplayedRangesKeepSourceOffsetsAcrossFiguresAndInlineTranslation() {
        let map = ReaderDisplayMap([(0, 5), (4, 7), (4, 3), (10, 8)])
        XCTAssertEqual(map.displayedRange(for: NSRange(location: 0, length: 4)), NSRange(location: 5, length: 4))
        XCTAssertEqual(map.displayedRange(for: NSRange(location: 4, length: 6)), NSRange(location: 19, length: 6))
        let original = NSRange(location: 2, length: 7)
        let displayed = map.displayedRange(for: original)
        XCTAssertEqual(map.sourceRange(for: displayed), original)
        XCTAssertEqual(map.displayedSegments(for: original), [NSRange(location: 7, length: 2), NSRange(location: 19, length: 5)])
        XCTAssertNil(map.sourceCharacter(at: 12))
        XCTAssertEqual(map.sourceBoundary(at: 28), 10)
    }

    @MainActor
    private func waitForSync(_ reader: ReaderModel) async throws {
        for _ in 0..<20 {
            await reader.syncTextLibrary()
            if !reader.textSync.isSyncing, !reader.textSync.hasPendingChanges { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("PDF sync did not settle")
    }

    private func makePDF(at url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 200, height: 140, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(red: 0.19, green: 0.48, blue: 0.72, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 140))
        let image = try XCTUnwrap(bitmap.makeImage())
        func line(_ text: String, at y: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            pdf.textPosition = CGPoint(x: 80, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), pdf)
        }
        pdf.beginPDFPage(nil)
        line("This is the first example.", at: 725)
        pdf.draw(image, in: CGRect(x: 80, y: 400, width: 426, height: 250))
        line("Look at the light.", at: 365)
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: CGRect(x: 80, y: 440, width: 420, height: 280))
        pdf.draw(image, in: CGRect(x: 80, y: 110, width: 420, height: 280))
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        line("The last page.", at: 650)
        pdf.endPDFPage()
        pdf.closePDF()
    }
}
