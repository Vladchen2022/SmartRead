import CryptoKit
import CoreGraphics
import Foundation

struct PDFBook: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let pageCount: Int
}

struct PDFBookLocation: Codable, Equatable, Sendable {
    let book: PDFBook
    let index: Int
    let englishOnly: Bool
    let usedOCR: Bool
    let sentenceEnding: String?
    var chapter: PDFChapterReading?

    var pageLabel: String { "第 \(index + 1)/\(book.pageCount) 页" }

    func sourcePage(at offset: Int) -> Int {
        chapter?.anchors.last(where: { $0.offset <= offset })?.page ?? index
    }
}

struct PDFBookPage: Codable, Sendable {
    let text: String
    let usedOCR: Bool
    var boxes: [CGRect]? = nil
}

enum PDFBookText {
    private static let han = try! NSRegularExpression(pattern: #"\p{Script=Han}"#)

    static func containsChinese(_ text: String) -> Bool {
        han.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isEnglish(_ text: String) -> Bool {
        !containsChinese(text) && WordLookup.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func englishOnly(_ text: String) -> String {
        text.components(separatedBy: "\n\n").filter(isEnglish).joined(separator: "\n\n")
    }

    static func normalizeLine(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnglish(line) else { return line }
        let spaced = line.replacingOccurrences(of: #"([．！？；：，])(?=[A-Za-z])"#, with: "$1 ", options: .regularExpression)
        return (spaced.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? spaced)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
    }

    static func hasSentenceEnding(_ text: String) -> Bool {
        let sentence = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: #""'’”)]」"#)))
        return sentence.last.map { ".!?…。！？".contains($0) } ?? false
    }
}

actor PDFBookStore {
    private let root: URL
    private var openDocument: (id: String, document: PDFImportDocument)?
    private var chapterIndex: (id: String, chapters: [PDFChapter])?

    init(root: URL) { self.root = root }

    func importBook(_ source: URL) async throws -> PDFBook {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let id = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let sourceBook = try await PDFImportDocument.open(source)
        try Task.checkCancellation()
        let destination = fileURL(id)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        if !files.fileExists(atPath: destination.path) {
            let staging = root.appending(path: ".\(UUID()).pdf")
            defer { try? files.removeItem(at: staging) }
            try files.copyItem(at: source, to: staging)
            try files.moveItem(at: staging, to: destination)
        }
        let name = sourceBook.name.replacingOccurrences(of: #"(?:_\d{4}-\d{2}-\d{2})+$"#, with: "", options: .regularExpression)
        return PDFBook(id: id, title: name.isEmpty ? sourceBook.name : name, pageCount: sourceBook.pageCount)
    }

    func article(for book: PDFBook, at index: Int, step: Int = 0, englishOnly: Bool) async throws -> Article? {
        guard (0..<book.pageCount).contains(index), [-1, 0, 1].contains(step) else { return nil }
        let document = try await document(for: book)
        var current = index
        while (0..<book.pageCount).contains(current) {
            try Task.checkCancellation()
            let page = try await page(at: current, of: book, document: document)
            let text = englishOnly ? PDFBookText.englishOnly(page.text) : page.text
            if step == 0 || !englishOnly || !text.isEmpty {
                let ending = await sentenceEnding(in: text, page: current, book: book, document: document)
                let location = PDFBookLocation(book: book, index: current, englishOnly: englishOnly,
                                               usedOCR: page.usedOCR, sentenceEnding: ending)
                return try Article(title: book.title, body: text, pdfPage: location)
            }
            current += step
        }
        return nil
    }

    func preview(_ location: PDFBookLocation, at index: Int?) async throws -> CGImage {
        try await document(for: location.book).preview(page: index ?? location.index)
    }

    func chapters(for book: PDFBook) async throws -> [PDFChapter] {
        if let chapterIndex, chapterIndex.id == book.id { return chapterIndex.chapters }
        let document = try await document(for: book)
        let headings = try await document.bookChapterHeadings()
        let chapters = headings.enumerated().map { i, heading in
            let end = i + 1 < headings.count ? headings[i + 1].startPage - 1 : book.pageCount - 1
            return PDFChapter(firstPage: heading.startPage, lastPage: end, heading: heading)
        }
        chapterIndex = (book.id, chapters)
        return chapters
    }

    func chapterArticle(for book: PDFBook, chapter: PDFChapter, englishOnly: Bool, join: PDFChapterJoin = .automatic,
                        replacing pageIndex: Int? = nil, with replacement: PDFBookPage? = nil) async throws -> Article {
        guard chapter.firstPage >= 0, chapter.firstPage <= chapter.lastPage, chapter.lastPage < book.pageCount else {
            throw ReaderError.message("请输入 1–\(book.pageCount) 范围内的起止页。")
        }
        let document = try await document(for: book)
        var assembly = PDFChapterAssembly(chapter: chapter, join: join)
        for index in chapter.firstPage...chapter.lastPage {
            try Task.checkCancellation()
            let extracted: PDFBookPage
            if index == pageIndex, let replacement { extracted = replacement }
            else { extracted = try await page(at: index, of: book, document: document) }
            try assembly.append(extracted, at: index)
        }
        return try assembly.article(for: book, englishOnly: englishOnly)
    }

    private func cacheURL(_ book: PDFBook, _ index: Int) -> URL {
        root.appending(path: book.id, directoryHint: .isDirectory).appending(path: "v2-\(index).json")
    }

    func savedBoxes(for book: PDFBook, at index: Int) throws -> [CGRect] {
        do { return try JSONDecoder().decode(PDFBookPage.self, from: Data(contentsOf: cacheURL(book, index))).boxes ?? [] }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    func correct(_ location: PDFBookLocation, at index: Int, boxes: [CGRect]) async throws -> Article {
        let book = location.book
        let document = try await document(for: book)
        let regions: [CGRect?] = boxes.isEmpty ? [nil] : boxes.map(Optional.some)
        var sections: [String] = []
        for (offset, region) in regions.enumerated() {
            let section = try await document.recognizeBookPage(at: index, box: region).text
            guard !section.isEmpty else { throw ReaderError.message("第 \(offset + 1) 个区域未识别到文字，原页内容已保留。") }
            sections.append(section)
        }
        let corrected = PDFBookPage(text: sections.joined(separator: "\n\n"), usedOCR: true, boxes: boxes)
        let article: Article
        if let reading = location.chapter {
            article = try await chapterArticle(for: book, chapter: reading.chapter, englishOnly: location.englishOnly,
                                               join: reading.join, replacing: index, with: corrected)
        } else {
            let text = location.englishOnly ? PDFBookText.englishOnly(corrected.text) : corrected.text
            let ending = await sentenceEnding(in: text, page: index, book: book, document: document)
            article = try Article(title: book.title, body: text, pdfPage: .init(book: book, index: index,
                englishOnly: location.englishOnly, usedOCR: true, sentenceEnding: ending))
        }
        try Task.checkCancellation()
        let url = cacheURL(book, index)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(corrected).write(to: url, options: .atomic)
        return article
    }

    private func fileURL(_ id: String) -> URL { root.appending(path: "\(id).pdf") }

    private func document(for book: PDFBook) async throws -> PDFImportDocument {
        if let openDocument, openDocument.id == book.id { return openDocument.document }
        let document = try await PDFImportDocument.open(fileURL(book.id))
        openDocument = (book.id, document)
        return document
    }

    private func page(at index: Int, of book: PDFBook, document: PDFImportDocument) async throws -> PDFBookPage {
        let url = cacheURL(book, index)
        let cache = url.deletingLastPathComponent()
        if let data = try? Data(contentsOf: url), let page = try? JSONDecoder().decode(PDFBookPage.self, from: data) {
            return page
        }
        let page = try await document.bookPage(at: index)
        if !page.text.isEmpty {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? JSONEncoder().encode(page).write(to: url, options: .atomic)
        }
        return page
    }

    private func sentenceEnding(in text: String, page: Int, book: PDFBook, document: PDFImportDocument) async -> String? {
        guard page + 1 < document.pageCount,
              let paragraph = text.components(separatedBy: "\n\n").last,
              PDFBookText.isEnglish(paragraph), !PDFBookText.hasSentenceEnding(paragraph),
              let next = try? await self.page(at: page + 1, of: book, document: document).text,
              let opening = next.components(separatedBy: "\n\n").first, PDFBookText.isEnglish(opening),
              let first = opening.first, first.isLowercase,
              let sentence = ReadingIndex(opening).articleSentences().first?.text,
              PDFBookText.hasSentenceEnding(sentence) else { return nil }
        return sentence
    }
}
