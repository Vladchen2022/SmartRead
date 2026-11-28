import CryptoKit
import Foundation
import NaturalLanguage

public struct ReadingChapter: Codable, Equatable, Identifiable, Sendable {
    public let page: Int
    public let title: String
    public var id: Int { page }

    public init(page: Int, title: String) {
        self.page = page
        self.title = title
    }
}

public struct ReadingMaterial: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let legacyKey: String
    public let title: String
    public let body: String
    public var sourceURL: URL?
    public var desktopMetadata: Data?
    public var bookID: String?
    public var page: Int?
    public var chapter: String?
    public var chapterTranslation: String?
    public var chapterCatalog: [ReadingChapter]?
    public var historyKey: String { bookID.map { "book/" + $0 } ?? "article/" + id }
    public var displayTitle: String { chapter.map { "\(title) · \($0)" } ?? title }

    public init(title: String, body: String, legacyKey: String? = nil, sourceURL: URL? = nil) throws {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        self.title = title.isEmpty ? "粘贴的文章" : title
        self.body = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.body.isEmpty, self.body.utf16.count <= 250_000 else {
            throw ReadingSyncError.invalidText
        }
        self.sourceURL = sourceURL
        let source = sourceURL?.absoluteString ?? self.title
        self.legacyKey = legacyKey ?? Self.digest("\(source.utf8.count):\(source)\(self.body)")
        id = Self.digest(self.legacyKey + ":" + Self.digest(self.body))
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ReadingAnchor: Codable, Equatable, Identifiable, Sendable {
    public let offset: Int
    public let length: Int
    public let quote: String
    public var id: Int { offset }

    public init(offset: Int, length: Int, quote: String) {
        self.offset = offset
        self.length = length
        self.quote = quote
    }

    public func matches(_ body: String) -> Bool {
        let text = body as NSString
        let source = quote as NSString
        guard offset >= 0, length > 0, offset <= text.length, length <= text.length - offset,
              length <= source.length else { return false }
        let range = NSRange(location: offset, length: length)
        guard Range(range, in: body) != nil, Range(NSRange(location: 0, length: length), in: quote) != nil else {
            return false
        }
        return text.substring(with: range).utf8.elementsEqual(source.substring(to: length).utf8)
    }

    public static func sentences(in text: String) -> [Self] {
        let source = text as NSString
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english)
        let visible = CharacterSet.whitespacesAndNewlines.inverted
        func anchor(_ range: NSRange, in text: NSString, offset: Int) -> Self? {
            let start = text.rangeOfCharacter(from: visible, range: range).location
            guard start != NSNotFound else { return nil }
            let end = NSMaxRange(text.rangeOfCharacter(from: visible, options: .backwards, range: range))
            let trimmed = NSRange(location: start, length: end - start)
            return Self(offset: offset + start, length: trimmed.length, quote: text.substring(with: trimmed))
        }
        var result: [Self] = []
        var offset = 0
        while offset < source.length {
            let range = source.paragraphRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(range)
            guard let paragraph = anchor(range, in: source, offset: 0) else { continue }
            let content = paragraph.quote
            tokenizer.string = content
            let sentences = tokenizer.tokens(for: content.startIndex..<content.endIndex).compactMap {
                anchor(NSRange($0, in: content), in: content as NSString, offset: paragraph.offset)
            }
            result += sentences.isEmpty ? [paragraph] : sentences
        }
        return result
    }
}

public struct ReadingProgress: Codable, Equatable, Sendable {
    public let offset: Int
    public let chapterOffset: Int?
    public let completed: Bool
    public let date: Date

    public init(offset: Int, chapterOffset: Int? = nil, completed: Bool, date: Date = .now) {
        self.offset = offset
        self.chapterOffset = chapterOffset
        self.completed = completed
        self.date = date
    }
}

public struct ReadingFavorite: Codable, Equatable, Identifiable, Sendable {
    public let kind: String
    public let anchor: ReadingAnchor
    public let sentence: String
    public var definition: String?
    public var translation: String?
    public var analysis: String?
    public let date: Date
    public var id: String { "\(kind):\(anchor.offset):\(anchor.length)" }

    public init(kind: String, anchor: ReadingAnchor, sentence: String, definition: String? = nil,
                translation: String? = nil, analysis: String? = nil, date: Date = .now) {
        self.kind = kind
        self.anchor = anchor
        self.sentence = sentence
        self.definition = definition
        self.translation = translation
        self.analysis = analysis
        self.date = date
    }
}

public struct ReadingMark: Equatable, Identifiable, Sendable {
    public let anchor: ReadingAnchor
    public let manuallyMarked: Bool
    public let slowCount: Int
    public let reviewedCount: Int
    public var needsReview: Bool { manuallyMarked || slowCount > reviewedCount }
    public var id: String { String(anchor.offset) + ":" + String(anchor.length) }
}

public enum ReadingSyncValue: Codable, Equatable, Sendable {
    case material(ReadingMaterial)
    case progress(material: String, ReadingProgress)
    case mark(material: String, ReadingAnchor, Bool)
    case slow(material: String, ReadingAnchor, device: String, count: Int)
    case reviewed(material: String, ReadingAnchor, seen: [String: Int])
    case favorite(material: String, id: String, ReadingFavorite?)

    var key: String {
        switch self {
        case .material(let material): return "material/" + material.id
        case .progress(let material, _): return "progress/" + material
        case .mark(let material, let anchor, _): return "mark/" + Self.markKey(material, anchor)
        case .slow(let material, let anchor, let device, _): return "slow/" + Self.markKey(material, anchor) + "/" + device
        case .reviewed(let material, let anchor, _): return "review/" + Self.markKey(material, anchor)
        case .favorite(let material, let id, _): return "favorite/" + material + "/" + id
        }
    }

    static func markKey(_ material: String, _ anchor: ReadingAnchor) -> String {
        "\(material)/\(anchor.offset):\(anchor.length)"
    }
}

public enum ReadingSyncError: LocalizedError {
    case invalidText, unavailableFolder, unsupportedVersion, invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidText: return "正文需要在 1 到 25 万字符之间。"
        case .unavailableFolder: return "无法访问同步文件夹，请重新选择。"
        case .unsupportedVersion: return "同步文件由更新的 SmartRead 版本创建。"
        case .invalidSnapshot: return "同步文件内容不完整，本地记录已保留。"
        }
    }
}
