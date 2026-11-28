import Foundation

struct PDFChapterHeading: Codable, Equatable, Sendable {
    let number: Int
    let text: String
    let startPage: Int

    // The Bookworms files use "1 Chapter", "Chapter 1", and "1 Title".
    static func read(_ line: String, on page: Int) -> Self? {
        let text = PDFBookText.normalizeLine(line)
        guard let number = PDFBookText.chapterNumber(in: text) else { return nil }
        return Self(number: number, text: text, startPage: page)
    }
}

struct PDFChapter: Codable, Equatable, Identifiable, Sendable {
    let firstPage: Int
    let lastPage: Int
    let heading: PDFChapterHeading?

    var id: String { "\(firstPage)-\(lastPage)-\(heading?.number ?? 0)" }
    var label: String {
        heading.map { "第 \($0.number) 章" } ?? sourceLabel
    }
    var menuLabel: String {
        guard let heading else { return sourceLabel }
        let title = heading.text.replacingOccurrences(of: #"(?i)^(?:chapter\s+\d+|\d+\s*(?:chapter\b|[.．])?)\s*"#, with: "", options: .regularExpression)
        return title.isEmpty ? label : "\(label) · \(title)"
    }
    var sourceLabel: String {
        firstPage == lastPage ? "PDF 第 \(firstPage + 1) 页" : "PDF 第 \(firstPage + 1)–\(lastPage + 1) 页"
    }
}

enum PDFChapterJoin: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, join, paragraph

    var id: Self { self }
    var label: String {
        switch self {
        case .automatic: "自动衔接"
        case .join: "接上上一段"
        case .paragraph: "保留段落换行"
        }
    }
}

struct PDFChapterReading: Codable, Equatable, Sendable {
    struct PageAnchor: Codable, Equatable, Sendable {
        let page: Int
        let offset: Int
    }

    let chapter: PDFChapter
    let join: PDFChapterJoin
    let translation: String
    let anchors: [PageAnchor]
}

struct PDFChapterAssembly {
    let chapter: PDFChapter
    let join: PDFChapterJoin
    private var english = ""
    private var chinese = ""
    private var anchors: [PDFChapterReading.PageAnchor] = []
    private var usesOCR = false

    mutating func append(_ page: PDFBookPage, at index: Int) throws {
        usesOCR = usesOCR || page.usedOCR
        var paragraphs = page.text.components(separatedBy: "\n\n")
        if index == chapter.firstPage, let heading = chapter.heading, let first = paragraphs.first,
           first.hasPrefix(heading.text) {
            paragraphs[0] = first.dropFirst(heading.text.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let original = paragraphs.filter(PDFBookText.isEnglish).joined(separator: "\n\n")
        if !original.isEmpty {
            let separator: String
            if english.isEmpty {
                separator = ""
            } else if let previous = anchors.last, previous.page + 1 == index, join != .paragraph,
                      join == .join || !PDFBookText.hasSentenceEnding(english) {
                separator = " "
            } else {
                separator = "\n\n"
            }
            anchors.append(.init(page: index, offset: english.utf16.count + separator.utf16.count))
            english += separator + original
        }
        let translated = paragraphs.filter(PDFBookText.containsChinese).joined(separator: "\n\n")
        if !translated.isEmpty {
            if !chinese.isEmpty { chinese += "\n\n" }
            chinese += translated
        }
        guard english.utf16.count <= Article.maximumLength, chinese.utf16.count <= Article.maximumLength else {
            throw ReaderError.message("所选范围的文字太长，请缩小页码范围。")
        }
    }

    func article(for book: PDFBook, englishOnly: Bool) throws -> Article {
        guard let first = anchors.first else { throw ReaderError.message("这个范围没有识别到英文正文。请检查起止页。") }
        let reading = PDFChapterReading(chapter: chapter, join: join, translation: chinese, anchors: anchors)
        let page = PDFBookLocation(book: book, index: first.page, englishOnly: englishOnly,
                                   usedOCR: usesOCR, sentenceEnding: nil, chapter: reading)
        return try Article(title: book.title, body: english, pdfPage: page)
    }
}
