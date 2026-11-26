import AppKit
import PDFKit
import XCTest
@testable import SmartRead

final class PDFBookTests: XCTestCase {
    func testChapterHeadingStylesAndManualPageBreaks() throws {
        XCTAssertEqual(PDFChapterHeading.read("Chapter 3 A Letter", on: 8)?.number, 3)
        XCTAssertEqual(PDFChapterHeading.read("2 Chapter", on: 5)?.number, 2)
        XCTAssertEqual(PDFChapterHeading.read("9 Where is Christine Daaé？", on: 8)?.number, 9)
        XCTAssertNil(PDFChapterHeading.read("9 死亡", on: 8))
        XCTAssertNil(PDFChapterHeading.read("The ninth chapter", on: 8))

        let book = PDFBook(id: "test", title: "Test book", pageCount: 3)
        let chapter = PDFChapter(firstPage: 0, lastPage: 2, heading: nil)
        let pages = [
            PDFBookPage(text: "She put the hat on the", usedOCR: false),
            PDFBookPage(text: "table. The door opened.\n\n她把帽子放在桌上。", usedOCR: false),
            PDFBookPage(text: "门打开了。", usedOCR: false)
        ]
        for join in PDFChapterJoin.allCases {
            var assembly = PDFChapterAssembly(chapter: chapter, join: join)
            for (page, text) in pages.enumerated() { try assembly.append(text, at: page) }
            let article = try assembly.article(for: book, englishOnly: false)
            let location = try XCTUnwrap(article.pdfPage)
            let separator = join == .paragraph ? "\n\n" : " "
            XCTAssertEqual(article.body, "She put the hat on the\(separator)table. The door opened.")
            XCTAssertEqual(location.chapter?.translation, "她把帽子放在桌上。\n\n门打开了。")
            let word = (article.body as NSString).range(of: "table")
            XCTAssertEqual(location.sourcePage(at: word.location), 1)
            XCTAssertEqual(location.sourcePage(at: word.location - 1), 0)
        }
    }

    @MainActor
    func testCrossPageFavoriteSavesTheFullQuoteAndJumpsToTheLocalWords() async throws {
        guard let path = ProcessInfo.processInfo.environment["SMARTREAD_TEST_PDF_BOOK"] else {
            throw XCTSkip("Set SMARTREAD_TEST_PDF_BOOK to Love or Money?")
        }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = URL.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let store = ArticleStore(root: root)
        let reader = ReaderModel(defaults: defaults, store: store, learningStore: .init(projectRoot: root))
        try await reader.importPDFBook(URL(fileURLWithPath: path))
        await reader.jumpToPDFPage(2)
        reader.weeklyFavorites.setFolder(root)
        let sentence = try XCTUnwrap(reader.articleForListening(fromHere: false).sentences.last)
        XCTAssertTrue(sentence.text.hasSuffix("down on the table."))
        try reader.saveFavorite(.init(kind: .sentence, excerpt: sentence, result: .init(translation: "她把帽子放在桌上。")))
        let favorite = try XCTUnwrap(reader.favorites.first?.favorite)
        XCTAssertEqual(favorite.selectedText, sentence.text)
        XCTAssertTrue(favorite.sentence.hasSuffix("on the table."))
        XCTAssertTrue(favorite.anchorText?.hasSuffix("on the") == true)
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.weeklyFavorites.isWorking && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let notes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let note = try XCTUnwrap(notes.first { $0.pathExtension == "md" })
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("down on the table."))
        await reader.turnPDFPage(1)
        try reader.showFavorite(favorite.id)
        XCTAssertEqual(reader.jump?.range, sentence.range)
        XCTAssertEqual(reader.article.pdfPage?.index, 1)
    }

    @MainActor
    func testBookwormsChaptersJoinAndResumeAcrossOriginalPages() async throws {
        guard let path = ProcessInfo.processInfo.environment["SMARTREAD_TEST_PDF_BOOK"] else {
            throw XCTSkip("Set SMARTREAD_TEST_PDF_BOOK to Love or Money?")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root.appending(path: "Library"))
        let learning = LearningRecordStore(projectRoot: root)
        var reader = ReaderModel(store: store, learningStore: learning)
        try await reader.importPDFBook(URL(fileURLWithPath: path))
        let book = try XCTUnwrap(reader.article.pdfPage?.book)
        let choices = try await reader.pdfChapterChoices(for: book)
        XCTAssertEqual(choices.map(\.heading?.number), Array(1...7).map(Optional.some))
        XCTAssertEqual(choices.map { $0.firstPage + 1 }, [2, 6, 12, 18, 25, 31, 36])

        await reader.jumpToPDFPage(2)
        let pageSentence = try XCTUnwrap(reader.articleForListening(fromHere: false).sentences.dropFirst().first)
        try reader.toggleFavorite(.init(kind: .sentence, excerpt: pageSentence, result: .init(translation: "页内译文")))
        let pageFavorite = try XCTUnwrap(reader.favorites.first)
        let didOpen = await reader.startPDFChapterReading()
        XCTAssertTrue(didOpen)
        let location = try XCTUnwrap(reader.article.pdfPage)
        let chapter = try XCTUnwrap(location.chapter)
        XCTAssertEqual(chapter.chapter.heading?.number, 1)
        XCTAssertEqual(chapter.anchors.map(\.page), [1, 2])
        XCTAssertTrue(chapter.translation.contains("克拉克森"))
        XCTAssertFalse(PDFBookText.containsChinese(reader.article.body))
        XCTAssertTrue(reader.article.body.contains("put it down on the table."))
        XCTAssertFalse(reader.article.body.contains("1 Chapter"))
        let spoken = reader.articleForListening(fromHere: false).sentences
        XCTAssertTrue(spoken.contains { $0.text.hasSuffix("put it down on the table.") })
        let joined = try XCTUnwrap(spoken.first { $0.text.hasSuffix("put it down on the table.") })
        try reader.toggleFavorite(.init(kind: .sentence, excerpt: joined, result: .init(translation: "跨页译文")))
        let joinedFavorite = try XCTUnwrap(reader.favorites.first)
        let table = (reader.article.body as NSString).range(of: "down on the table.").location
        let boundary = try XCTUnwrap(chapter.anchors.last?.offset)
        XCTAssertLessThan(table, boundary)
        reader.didScroll(to: table)
        reader.didScroll(to: boundary)
        XCTAssertEqual(reader.pdfProgress(for: reader.article), "第 1 章 · PDF 第 3 页")
        try reader.importText("A different article.", title: "Other")
        XCTAssertEqual(reader.history.count, 1)
        reader = ReaderModel(store: store, learningStore: learning)
        let historyEntry = try XCTUnwrap(reader.history.first)
        try reader.openHistoryArticle(historyEntry.id)
        XCTAssertEqual(reader.jump?.range.location, boundary)
        XCTAssertEqual(reader.currentPDFSourcePage, 2)
        let preview = try await reader.pdfPagePreview(location, at: reader.currentPDFSourcePage)
        XCTAssertGreaterThan(preview.width, 500)

        try await reader.loadPDFChapter(choices[1])
        XCTAssertEqual(reader.article.pdfPage?.chapter?.chapter.heading?.number, 2)
        XCTAssertTrue(reader.article.body.contains("It was seven o'clock"))
        XCTAssertEqual(reader.favoriteCount, 2)
        reader = ReaderModel(store: store, learningStore: learning)
        XCTAssertEqual(reader.favoriteCount, 2)
        try reader.showFavorite(pageFavorite.id)
        XCTAssertNil(reader.article.pdfPage?.chapter)
        XCTAssertEqual(reader.article.pdfPage?.index, 1)
        XCTAssertEqual(reader.shownFavorite?.result.translation, "页内译文")
        try reader.showFavorite(joinedFavorite.id)
        XCTAssertEqual(reader.article.pdfPage?.chapter?.chapter.heading?.number, 1)
        XCTAssertEqual(reader.jump?.range, joined.range)
        XCTAssertEqual(reader.shownFavorite?.result.translation, "跨页译文")
        reader.selection = nil
        reader.didScroll(to: boundary)
        XCTAssertEqual(reader.currentPDFSourcePage, 2)
        await reader.openPDFPageView()
        XCTAssertEqual(reader.article.pdfPage?.index, 2)
        XCTAssertNil(reader.article.pdfPage?.chapter)
        XCTAssertTrue(PDFBookText.containsChinese(reader.article.body))
        try reader.removeFavorite(joinedFavorite.id)
        XCTAssertEqual(reader.favoriteCount, 1)

        let titled = URL(fileURLWithPath: path).deletingLastPathComponent()
        let adjacent = try FileManager.default.contentsOfDirectory(at: titled, includingPropertiesForKeys: nil)
        for (prefix, pages) in [("002_", [2, 6, 10, 15, 19, 24, 29, 35, 38]), ("007_", [2, 8, 13, 16, 19, 25, 30])] {
            if let file = adjacent.first(where: { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "pdf" }) {
                let doc = try await PDFImportDocument.open(file)
                let headings = try await doc.bookChapterHeadings()
                XCTAssertEqual(headings.map { $0.startPage + 1 }, pages, prefix)
            }
        }
    }

    @MainActor
    func testBilingualBookKeepsPagesAndRestoresExactPosition() async throws {
        guard let path = ProcessInfo.processInfo.environment["SMARTREAD_TEST_PDF_BOOK"] else {
            throw XCTSkip("Set SMARTREAD_TEST_PDF_BOOK to Love or Money?")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "爱情与金钱_2026-03-05.pdf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: file)
        let store = ArticleStore(root: root.appending(path: "Library"))
        let learning = LearningRecordStore(projectRoot: root)
        var reader = ReaderModel(store: store, learningStore: learning)
        try await reader.importPDFBook(file)
        let book = try XCTUnwrap(reader.article.pdfPage?.book)
        XCTAssertEqual(book.pageCount, 41)
        XCTAssertEqual(book.title, "爱情与金钱")
        XCTAssertEqual(reader.article.pdfPage?.index, 0)
        let cache = store.pdfBooksDirectory.appending(path: book.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["v2-0.json"])
        try FileManager.default.removeItem(at: file)

        await reader.turnPDFPage(1)
        XCTAssertEqual(reader.article.pdfPage?.index, 1)
        XCTAssertEqual(reader.article.pdfPage?.usedOCR, false)
        XCTAssertTrue(reader.article.body.contains("The Clarkson family lived in the country near Cambridge"))
        XCTAssertTrue(reader.article.body.contains("\n\n"))
        XCTAssertTrue(reader.articleForListening(fromHere: false).sentences.last?.text.hasSuffix("on the table.") == true,
                      reader.articleForListening(fromHere: false).sentences.last?.text ?? "")

        await reader.turnPDFPage(1)
        XCTAssertEqual(reader.article.pdfPage?.index, 2)
        let english = (reader.article.body as NSString).range(of: "sandwiches")
        XCTAssertNotEqual(english.location, NSNotFound)
        XCTAssertTrue(reader.clickText(at: english.location, wholeSentence: false))
        reader.cancelLookup()
        let lookup = reader.lookup
        let chinese = (reader.article.body as NSString).range(of: "克拉克森")
        XCTAssertNotEqual(chinese.location, NSNotFound)
        XCTAssertFalse(reader.clickText(at: chinese.location, wholeSentence: true))
        reader.selection = TextExcerpt(text: "克拉克森", range: chinese, context: "")
        XCTAssertFalse(reader.hasEnglishSelection)
        XCTAssertNil(reader.assistantSentenceTarget)
        reader.lookUp(.translation)
        XCTAssertEqual(reader.lookup, lookup)

        await reader.turnPDFPage(1)
        XCTAssertEqual(reader.article.pdfPage?.index, 3)
        XCTAssertTrue(PDFBookText.containsChinese(reader.article.body))
        XCTAssertFalse(reader.hasEnglishReadingText)
        XCTAssertTrue(reader.articleForListening(fromHere: false).sentences.isEmpty)
        XCTAssertTrue(reader.history.isEmpty)

        await reader.turnPDFPage(-1)
        await reader.setPDFEnglishOnly(true)
        XCTAssertFalse(PDFBookText.containsChinese(reader.article.body))
        await reader.turnPDFPage(1)
        XCTAssertEqual(reader.article.pdfPage?.index, 5)
        let sentence = try XCTUnwrap(reader.articleForListening(fromHere: false).sentences.dropFirst(2).first)
        reader.didScroll(to: sentence.range.location)
        try reader.importText("A normal article.", title: "An article")
        XCTAssertEqual(reader.history.count, 1)
        XCTAssertEqual(reader.history.first?.article.pdfPage?.pageLabel, "第 6/41 页")
        reader = ReaderModel(store: store, learningStore: learning)
        try reader.openHistoryArticle(try XCTUnwrap(reader.history.first?.id))
        XCTAssertEqual(reader.article.pdfPage?.pageLabel, "第 6/41 页")
        XCTAssertEqual(reader.jump?.range, sentence.range)
        XCTAssertTrue(reader.jump?.alignToTop == true)
        let restarted = ReaderModel(store: store, learningStore: learning)
        XCTAssertEqual(restarted.article.pdfPage?.index, 5)
        XCTAssertEqual(restarted.jump?.range, sentence.range)
        let original = try await restarted.pdfPagePreview(try XCTUnwrap(restarted.article.pdfPage))
        XCTAssertGreaterThan(original.width, 500)
    }

    func testBookOCRKeepsChineseFromARasterPage() async throws {
        guard let path = ProcessInfo.processInfo.environment["SMARTREAD_TEST_PDF_BOOK"] else {
            throw XCTSkip("Set SMARTREAD_TEST_PDF_BOOK to Love or Money?")
        }
        let original = try await PDFImportDocument.open(URL(fileURLWithPath: path))
        let bitmap = try await original.preview(page: 3)
        let page = try XCTUnwrap(PDFPage(image: NSImage(cgImage: bitmap, size: .zero)))
        let scanned = PDFDocument()
        scanned.insert(page, at: 0)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(scanned.write(to: url))
        let importer = try await PDFImportDocument.open(url)
        let ocr = try await importer.bookPage(at: 0)
        XCTAssertTrue(ocr.usedOCR)
        XCTAssertTrue(ocr.text.contains("杰基"))
        XCTAssertTrue(PDFBookText.englishOnly(ocr.text).isEmpty)
    }
}
