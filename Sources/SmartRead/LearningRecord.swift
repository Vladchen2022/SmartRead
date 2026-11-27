import CryptoKit
import Foundation

enum ReadingDifficulty: String, CaseIterable, Codable, Identifiable, Sendable {
    case tooEasy, justRight, tooHard

    var id: Self { self }
    var label: String {
        switch self {
        case .tooEasy: "偏易"
        case .justRight: "刚好"
        case .tooHard: "偏难"
        }
    }
}

enum ReadingDifficultyReason: String, CaseIterable, Codable, Identifiable, Sendable {
    case vocabulary, phrases, longSentences, background

    var id: Self { self }
    var label: String {
        switch self {
        case .vocabulary: "生词多"
        case .phrases: "搭配难"
        case .longSentences: "长句难"
        case .background: "背景陌生"
        }
    }
}

struct ReadingFeedback: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case inProgress, completed }

    var status: Status = .inProgress
    var completedAt: Date?
    var difficulty: ReadingDifficulty?
    var difficultyReason: ReadingDifficultyReason?
    var feedback: String?

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(status, forKey: .status)
        try values.encode(completedAt, forKey: .completedAt)
        try values.encode(difficulty, forKey: .difficulty)
        try values.encodeIfPresent(difficultyReason, forKey: .difficultyReason)
        try values.encode(feedback, forKey: .feedback)
    }

    private enum CodingKeys: CodingKey { case status, completedAt, difficulty, difficultyReason, feedback }
}

struct LearningFavorite: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case word, phrase, sentence, grammar, originalSentence

        var label: String {
            switch self {
            case .word: "单词"
            case .phrase: "搭配"
            case .sentence: "句子"
            case .grammar: "语法"
            case .originalSentence: "原句"
            }
        }
    }

    struct Result: Codable, Equatable, Sendable {
        var definition: String?
        var translation: String?
        var analysis: String?
    }

    struct Draft {
        let kind: Kind
        let excerpt: TextExcerpt
        let result: Result
    }

    struct Location: Codable, Equatable, Sendable {
        let location: Int
        let length: Int

        init(_ range: NSRange) {
            location = range.location
            length = range.length
        }
    }

    let favoriteId: String
    let kind: Kind
    var selectedText: String
    var sentence: String
    let paragraph: Int
    let range: Location
    let result: Result
    let createdAt: Date
    let updatedAt: Date
    var anchorText: String? = nil
    var id: String { favoriteId }

    var displayQuote: String {
        guard kind == .grammar, !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return selectedText
        }
        return sentence
    }

    mutating func completePDFSentence(in body: String, ending: String) {
        let bodyLength = body.utf16.count
        guard range.location >= 0, range.length > 0, range.location <= bodyLength,
              range.length <= bodyLength - range.location else { return }
        if body.hasSuffix(sentence), range.location >= bodyLength - sentence.utf16.count,
           !PDFBookText.hasSentenceEnding(sentence) {
            sentence += " " + ending
        }
        if (kind == .sentence || kind == .grammar), anchorText == nil,
           range.length == bodyLength - range.location, selectedText.utf16.count == range.length,
           body.hasSuffix(selectedText), !PDFBookText.hasSentenceEnding(selectedText) {
            anchorText = selectedText
            selectedText += " " + ending
        }
    }

    static func id(articleId: UUID, kind: Kind, range: NSRange) -> String {
        "\(articleId.uuidString.lowercased()):\(kind.rawValue):\(range.location):\(range.length)"
    }
}

struct LearningRecord: Codable, Sendable {
    let schemaVersion: Int
    let articleId: UUID
    var sourceId: String?
    var title: String
    var readingDate: String?
    var sourcePath: String?
    var course: String?
    var lesson: String?
    var titleZh: String?
    let body: String
    let bodySha256: String
    let offsetUnit: String
    var reading = ReadingFeedback()
    var favorites: [LearningFavorite] = []
    var pdfPage: PDFBookLocation?
    var importedLegacy: Bool?
    var importedWebURL: URL?
    var updatedAt: Date

    init(article: Article, now: Date) {
        schemaVersion = 1
        articleId = UUID()
        title = article.title
        body = article.body
        bodySha256 = Self.fingerprint(article.body)
        offsetUnit = "utf16"
        updatedAt = now
        pdfPage = article.pdfPage
        if article.learningSource == nil { importedWebURL = article.sourceURL }
        _ = updateSource(from: article)
    }

    static func fingerprint(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    mutating func updateSource(from article: Article) -> Bool {
        guard let source = article.learningSource else { return false }
        guard sourceId != source.sourceId || title != article.title || readingDate != source.readingDate ||
              sourcePath != source.path || course != source.course || lesson != source.lesson || titleZh != source.titleZh else {
            return false
        }
        sourceId = source.sourceId
        title = article.title
        readingDate = source.readingDate
        sourcePath = source.path
        course = source.course
        lesson = source.lesson
        titleZh = source.titleZh
        return true
    }

    mutating func touch() -> Date {
        updatedAt = max(Date(), updatedAt.addingTimeInterval(0.001))
        return updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(articleId.uuidString.lowercased(), forKey: .articleId)
        try values.encode(sourceId, forKey: .sourceId)
        try values.encode(title, forKey: .title)
        try values.encode(readingDate, forKey: .readingDate)
        try values.encode(sourcePath, forKey: .sourcePath)
        try values.encodeIfPresent(course, forKey: .course)
        try values.encodeIfPresent(lesson, forKey: .lesson)
        try values.encodeIfPresent(titleZh, forKey: .titleZh)
        try values.encode(body, forKey: .body)
        try values.encode(bodySha256, forKey: .bodySha256)
        try values.encode(offsetUnit, forKey: .offsetUnit)
        try values.encode(reading, forKey: .reading)
        try values.encode(favorites, forKey: .favorites)
        try values.encodeIfPresent(pdfPage, forKey: .pdfPage)
        try values.encodeIfPresent(importedLegacy, forKey: .importedLegacy)
        try values.encodeIfPresent(importedWebURL, forKey: .importedWebURL)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion, articleId, sourceId, title, readingDate, sourcePath, course, lesson, titleZh
        case body, bodySha256, offsetUnit, reading, favorites, updatedAt, pdfPage, importedLegacy, importedWebURL
    }
}

struct LearningRecordScan {
    let record: LearningRecord?
    let unreadable: [String]
}

actor BackgroundLearningRecords {
    private let store: LearningRecordStore
    init(store: LearningRecordStore) { self.store = store }

    func load(for article: Article) throws -> LearningRecord? {
        try Task.checkCancellation()
        return try store.load(for: article)
    }

    func scan(for article: Article) throws -> LearningRecordScan {
        try Task.checkCancellation()
        return try store.scan(for: article)
    }
}

struct LearningRecordStore: Sendable {
    let projectRoot: URL
    var directory: URL { projectRoot.appending(path: "SmartRead 学习记录", directoryHint: .isDirectory) }

    init(projectRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/英语精读计划")) {
        self.projectRoot = projectRoot
    }

    func sourcePath(for url: URL) -> String? {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let file = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard file.count > root.count, file.starts(with: root) else { return nil }
        return file.dropFirst(root.count).joined(separator: "/")
    }

    func file(for id: UUID) -> URL {
        directory.appending(path: id.uuidString.lowercased() + ".json")
    }

    func load(for article: Article) throws -> LearningRecord? {
        try scan(for: article).record
    }

    private func identityFile(sourceID: String, bodyHash: String) -> URL {
        directory.appending(path: ".sources", directoryHint: .isDirectory)
            .appending(path: LearningRecord.fingerprint(sourceID + ":" + bodyHash))
    }

    func scan(for article: Article) throws -> LearningRecordScan {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                               options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return LearningRecordScan(record: nil, unreadable: [])
        }

        let fingerprint = LearningRecord.fingerprint(article.body)
        let sourceId = article.learningSource?.sourceId
        let identity = sourceId.map { identityFile(sourceID: $0, bodyHash: fingerprint) }
        let mapped = try identity.flatMap { url -> String? in
            do { return try String(contentsOf: url, encoding: .utf8) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        var unreadable: [String] = []
        var matches: [LearningRecord] = []
        for url in files where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let record: LearningRecord
            do {
                record = try Self.read(url)
                guard record.articleId == id else { throw ReaderError.message("记录编号不匹配。") }
            } catch {
                if mapped.flatMap(UUID.init(uuidString:)) == id || Self.matchesDamagedFile(url, article: article, hash: fingerprint) {
                    throw ReaderError.message("本篇的学习记录 \(url.lastPathComponent) 无法读取，已保留原件。")
                }
                unreadable.append(url.lastPathComponent)
                continue
            }
            if record.bodySha256 == fingerprint, record.body.utf8.elementsEqual(article.body.utf8) {
                matches.append(record)
            }
        }
        let record = matches.first(where: { $0.sourceId == sourceId }) ?? (matches.count == 1 &&
            (sourceId == nil || matches[0].sourceId == nil) ? matches[0] : nil)
        if record == nil, let mapped {
            throw ReaderError.message("本篇已有关联记录 \(mapped)，请检查学习记录目录。")
        }
        if let record, let identity, mapped != record.articleId.uuidString {
            try? remember(record.articleId, at: identity)
        }
        return LearningRecordScan(record: record, unreadable: unreadable.sorted())
    }

    private static func matchesDamagedFile(_ url: URL, article: Article, hash: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["sourceId"] as? String == article.learningSource?.sourceId else { return false }
        return fields["bodySha256"] as? String == hash || fields["body"] as? String == article.body
    }

    private func remember(_ id: UUID, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try id.uuidString.write(to: url, atomically: true, encoding: .utf8)
    }

    func save(_ record: LearningRecord) throws {
        let url = file(for: record.articleId)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Self.read(url)
            guard existing.articleId == record.articleId, existing.bodySha256 == record.bodySha256 else {
                throw ReaderError.message("原学习记录与本篇不匹配，已保留原件。")
            }
        }
        var newIdentity: URL?
        if let source = record.sourceId {
            let identity = identityFile(sourceID: source, bodyHash: record.bodySha256)
            let mapped: String?
            do { mapped = try String(contentsOf: identity, encoding: .utf8) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { mapped = nil }
            if let mapped {
                guard UUID(uuidString: mapped) == record.articleId else {
                    throw ReaderError.message("本篇已有关联的学习记录，已停止写入。")
                }
            } else {
                try remember(record.articleId, at: identity)
                newIdentity = identity
            }
        }
        do { try Self.write(record, to: url) }
        catch {
            if let newIdentity { try? FileManager.default.removeItem(at: newIdentity) }
            throw error
        }
    }

    static func read(_ url: URL) throws -> LearningRecord {
        var record = try makeDecoder().decode(LearningRecord.self, from: Data(contentsOf: url))
        guard record.schemaVersion == 1, record.offsetUnit == "utf16" else {
            throw ReaderError.message("无法识别学习记录 \(url.lastPathComponent)。")
        }
        if let ending = record.pdfPage?.sentenceEnding {
            for i in record.favorites.indices {
                record.favorites[i].completePDFSentence(in: record.body, ending: ending)
            }
        }
        return record
    }

    static func write(_ record: LearningRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let timestamp = Self.timestampFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(timestamp.string(from: date))
        }
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let timestamp = timestampFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            guard let date = timestamp.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "无效的学习记录时间")
            }
            return date
        }
        return decoder
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
