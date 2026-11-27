import Foundation
import NaturalLanguage

struct Article: Codable, Equatable, Sendable {
    let title: String
    let body: String
    let sourceURL: URL?
    let byline: String?
    let wordCount: Int
    let learningSource: LearningArticleSource?
    let pdfPage: PDFBookLocation?

    static let maximumLength = 250_000

    init(title: String, body: String, sourceURL: URL? = nil, byline: String? = nil,
         learningSource: LearningArticleSource? = nil, pdfPage: PDFBookLocation? = nil) throws {
        let cleanBody = Self.normalizedBody(body)
        guard !cleanBody.isEmpty || pdfPage != nil else { throw ReaderError.message("没有可导入的正文。") }
        guard cleanBody.utf16.count <= Self.maximumLength else {
            throw ReaderError.message("正文超过 25 万字符，请分段导入。")
        }
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        self.body = cleanBody
        self.sourceURL = sourceURL
        self.byline = byline
        self.learningSource = learningSource
        self.pdfPage = pdfPage
        wordCount = WordLookup.pattern.numberOfMatches(in: cleanBody, range: NSRange(cleanBody.startIndex..., in: cleanBody))
    }

    static func normalizedBody(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matchesImport(_ other: Article) -> Bool {
        if let sourceId = learningSource?.sourceId, sourceId == other.learningSource?.sourceId {
            return body.utf8.elementsEqual(other.body.utf8)
        }
        return self == other
    }

    func matchesReadingItem(_ other: Article) -> Bool {
        if let pdfPage, let otherPage = other.pdfPage { return pdfPage.book.id == otherPage.book.id }
        return matchesImport(other)
    }

    static func pasted(_ text: String, title: String = "") throws -> Article {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try Article(title: name.isEmpty ? "粘贴的文章" : name, body: text)
    }

    static let sample: Article = {
        let body = """
        The weather forecast promised a dry afternoon, so Nora left her umbrella at home and took the long way to the library. At the end of the lane, she stopped on the river bank to watch the water rise. A few steps farther on, a sign pointed to the bank where she had opened her first savings account.

        By the time she reached the library, it had started to rain. Rather than hurry home, she settled into a chair by the window and picked up a book she had been meaning to read for months.

        She had gone out to return a book. She ended up staying until closing time.
        """
        return try! Article(title: "The Long Way to the Library", body: body)
    }()
}

struct ArticleHistoryEntry: Codable, Identifiable {
    var id = UUID()
    let article: Article
    let lastReadAt: Date
}

struct ArticleLibrary: Codable {
    var current: Article?
    var history: [ArticleHistoryEntry] = []

    mutating func open(_ article: Article) {
        if let current, current.matchesReadingItem(article) {
            self.current = article
            return
        }
        history.removeAll { $0.article.matchesReadingItem(article) }
        if let current {
            history.insert(ArticleHistoryEntry(article: current, lastReadAt: Date()), at: 0)
        }
        current = article
    }
}

enum ReaderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let description): description
        }
    }
}

struct TextExcerpt: Hashable {
    let text: String
    let range: NSRange
    let context: String
    var contextWordRange: NSRange?

    var markedContext: String {
        guard let contextWordRange else { return context }
        return (context as NSString).replacingCharacters(in: contextWordRange, with: "⟦\(text)⟧")
    }
}

enum WordLookup {
    static let pattern = try! NSRegularExpression(
        pattern: #"[\p{Script=Latin}][\p{Script=Latin}\p{M}]*(?:['’‐‑-][\p{Script=Latin}][\p{Script=Latin}\p{M}]*)*"#
    )

    static func excerpt(at index: Int, in text: String) -> TextExcerpt? {
        let body = text as NSString
        guard index >= 0, index < body.length else { return nil }
        let paragraphRange = body.paragraphRange(for: NSRange(location: index, length: 0))
        let match = pattern.matches(in: text, range: paragraphRange)
            .first { NSLocationInRange(index, $0.range) }
        guard let match else { return nil }
        let word = body.substring(with: match.range)

        let paragraph = body.substring(with: paragraphRange)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        tokenizer.setLanguage(.english)
        let localWord = NSRange(location: match.range.location - paragraphRange.location, length: match.range.length)
        let sentence = Range(localWord, in: paragraph).map { NSRange(tokenizer.tokenRange(at: $0.lowerBound), in: paragraph) }
            ?? NSRange(location: 0, length: (paragraph as NSString).length)
        let start = min(localWord.location, max(sentence.location, localWord.location - 450))
        let end = max(NSMaxRange(localWord), min(NSMaxRange(sentence), NSMaxRange(localWord) + 450))
        let paragraphText = paragraph as NSString
        let contextRange = paragraphText.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let content = CharacterSet.whitespacesAndNewlines.inverted
        let first = paragraphText.rangeOfCharacter(from: content, range: contextRange).location
        let last = paragraphText.rangeOfCharacter(from: content, options: .backwards, range: contextRange)
        let context = paragraphText.substring(with: NSRange(location: first, length: NSMaxRange(last) - first))
        let contextWord = NSRange(location: localWord.location - first, length: localWord.length)
        return TextExcerpt(text: word, range: match.range, context: context, contextWordRange: contextWord)
    }
}

struct ArticleStore {
    private let file: URL
    private let positionFile: URL
    let pdfBooksDirectory: URL
    let importedLearningDirectory: URL
    let weeklyFavoriteQueueFile: URL
    let questionFavoritesFile: URL
    let listeningMarksFile: URL

    init(root: URL = URL.applicationSupportDirectory.appending(path: "SmartRead", directoryHint: .isDirectory)) {
        file = root.appending(path: "CurrentArticle.json")
        positionFile = root.appending(path: "ReadingPositions.json")
        pdfBooksDirectory = root.appending(path: "PDFBooks", directoryHint: .isDirectory)
        importedLearningDirectory = root.appending(path: "ImportedLearning", directoryHint: .isDirectory)
        weeklyFavoriteQueueFile = root.appending(path: "WeeklyFavoriteQueue.json")
        questionFavoritesFile = root.appending(path: "QuestionFavorites.json")
        listeningMarksFile = root.appending(path: "ListeningMarks.json")
    }

    enum RecordFile: String, CaseIterable, Identifiable {
        case library, positions
        var id: Self { self }
        var title: String { self == .library ? "文章历史" : "阅读进度" }
    }

    func url(for kind: RecordFile) -> URL { kind == .library ? file : positionFile }

    private func dataIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func decodeLibrary(_ data: Data) throws -> ArticleLibrary {
        let decoder = JSONDecoder()
        if let library = try? decoder.decode(ArticleLibrary.self, from: data) { return library }
        return ArticleLibrary(current: try decoder.decode(Article.self, from: data))
    }

    private func validate(_ data: Data, kind: RecordFile) throws {
        switch kind {
        case .library: _ = try decodeLibrary(data)
        case .positions: _ = try JSONDecoder().decode([String: SavedReadingPosition].self, from: data)
        }
    }

    private func currentData(_ kind: RecordFile) throws -> Data? {
        let url = url(for: kind)
        let data = try dataIfPresent(url)
        if data == nil, FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path) {
            throw ReaderError.message("主文件缺失，可从备份恢复。")
        }
        return data
    }

    func load() throws -> ArticleLibrary {
        try currentData(.library).map(decodeLibrary) ?? ArticleLibrary()
    }

    func loadPositions() throws -> [String: SavedReadingPosition] {
        try currentData(.positions).map { try JSONDecoder().decode([String: SavedReadingPosition].self, from: $0) } ?? [:]
    }

    private func save(_ data: Data, kind: RecordFile) throws {
        let url = url(for: kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = try currentData(kind)
        if let previous { try validate(previous, kind: kind) }
        try (previous ?? data).write(to: url.appendingPathExtension("backup"), options: .atomic)
        try data.write(to: url, options: .atomic)
    }

    func save(_ library: ArticleLibrary) throws { try save(JSONEncoder().encode(library), kind: .library) }
    func savePositions(_ positions: [String: SavedReadingPosition]) throws {
        try save(JSONEncoder().encode(positions), kind: .positions)
    }

    func recover(_ kind: RecordFile) throws {
        let url = url(for: kind)
        let original = try dataIfPresent(url)
        if let original, (try? validate(original, kind: kind)) != nil { return }
        let backupURL = url.appendingPathExtension("backup")
        var backup = try dataIfPresent(backupURL)
        if let bytes = backup, (try? validate(bytes, kind: kind)) == nil {
            try bytes.write(to: backupURL.appendingPathExtension("damaged-\(UUID())"), options: .withoutOverwriting)
            backup = nil
        }
        if let original {
            try original.write(to: url.appendingPathExtension("damaged-\(UUID().uuidString)"), options: .withoutOverwriting)
        }
        let replacement = try backup ?? (kind == .library ? JSONEncoder().encode(ArticleLibrary()) : Data("{}".utf8))
        try replacement.write(to: url, options: .atomic)
    }

}

struct SavedReadingPosition: Codable, Equatable {
    let sentenceStart: Int
    let completed: Bool
    var chapterOffset: Int?

    static func key(for article: Article) -> String {
        if let page = article.pdfPage { return key(for: page) }
        let source = article.learningSource?.sourceId ?? article.sourceURL?.absoluteString ?? article.title
        return LearningRecord.fingerprint("\(source.utf8.count):\(source)\(article.body)")
    }

    static func key(for page: PDFBookLocation) -> String {
        if let reading = page.chapter {
            return "pdf:\(page.book.id):chapter:\(reading.chapter.id):\(reading.join.rawValue)"
        }
        return "pdf:\(page.book.id):\(page.index):\(page.englishOnly ? "en" : "all")"
    }
}
