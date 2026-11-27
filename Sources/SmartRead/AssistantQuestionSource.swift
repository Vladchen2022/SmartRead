import Foundation
import Observation

struct AssistantQuestionSource: Codable, Equatable, Sendable {
    struct Cue: Codable, Equatable, Sendable {
        let start: Int64
        let text: String
    }

    enum Location: Codable, Equatable, Sendable {
        case text(material: String, range: NSRange, pdf: PDFBookLocation?)
        case audio(entry: UUID, cue: UUID, range: NSRange)
        case video(file: URL, cues: [Cue])
    }

    enum VideoTrack: Codable, Equatable, Sendable {
        case external(URL)
        case embedded(Int)
    }

    let title: String
    let location: Location
    var videoTrack: VideoTrack? = nil

    var mode: ReaderMode {
        switch location {
        case .text: .text
        case .audio: .audio
        case .video: .video
        }
    }

    var materialID: String {
        switch location {
        case .text(let material, _, _): material
        case .audio(let entry, _, _): entry.uuidString
        case .video(let file, _): file.absoluteString
        }
    }

    var positionID: String {
        switch location {
        case .text(_, let range, _): String(range.location)
        case .audio(_, let cue, let range): "\(cue):\(range.location)"
        case .video(_, let cues): cues.first.map { String($0.start) } ?? ""
        }
    }

    var linkableLength: Int {
        switch location {
        case .text(_, let range, _), .audio(_, _, let range): range.length
        case .video(_, let cues): cues.map(\.text).joined(separator: " ").utf16.count
        }
    }
}

extension AssistantQuestionReference {
    func sourceRange(in content: String, at original: NSRange, excerpt: NSRange?) -> NSRange? {
        let text = content as NSString
        let quoted = passage as NSString
        guard original.location >= 0, original.length > 0, original.location <= text.length,
              original.length <= text.length - original.location, original.length <= quoted.length,
              text.substring(with: original).utf8.elementsEqual(quoted.substring(to: original.length).utf8) else { return nil }
        guard let excerpt else { return original }
        guard excerpt.location >= 0, excerpt.length > 0, excerpt.location <= original.length,
              excerpt.length <= original.length - excerpt.location else { return nil }
        return NSRange(location: original.location + excerpt.location, length: excerpt.length)
    }
}

struct AssistantQuestionFavorite: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let question: String
    let answer: String
    let reference: AssistantQuestionReference?
    let mode: ReaderMode
    let savedAt: Date
    var weeklyOrigin: WeeklyFavoriteOrigin? = nil

    var weeklyID: String { Self.weeklyID(for: id) }
    static func weeklyID(for id: UUID) -> String { "question:" + id.uuidString.lowercased() }
}

@MainActor
@Observable
final class AssistantQuestionFavorites {
    private let file: URL
    private(set) var entries: [AssistantQuestionFavorite] = []
    private(set) var loadError: String?

    init(file: URL) {
        self.file = file
        do {
            entries = try Self.read(file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        } catch {
            loadError = "无法读取问答收藏。\(error.localizedDescription)"
        }
    }

    nonisolated static func read(_ file: URL) throws -> [AssistantQuestionFavorite] {
        try JSONDecoder().decode([AssistantQuestionFavorite].self, from: Data(contentsOf: file))
    }

    func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }

    func toggle(_ turn: AssistantQuestionTurn, mode: ReaderMode, weeklyOrigin: WeeklyFavoriteOrigin? = nil,
                stage: (AssistantQuestionFavorite) -> Void = { _ in }) throws {
        guard turn.isComplete else { return }
        if contains(turn.id) { try remove(turn.id); return }
        guard let reference = turn.reference, reference.hasOriginalPassage else {
            throw ReaderError.message("请先引用原句，再重新提问后收藏。")
        }
        let item = AssistantQuestionFavorite(id: turn.id, question: turn.question, answer: turn.answer,
                                             reference: reference, mode: mode, savedAt: .now, weeklyOrigin: weeklyOrigin)
        stage(item)
        try save([item] + entries)
    }

    func remove(_ id: UUID) throws {
        try save(entries.filter { $0.id != id })
    }

    private func save(_ next: [AssistantQuestionFavorite]) throws {
        if let loadError { throw ReaderError.message(loadError) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        entries = next
    }
}

struct AssistantAnswerLinks {
    private static let quotes = try! NSRegularExpression(pattern: #"\x60([^\x60\n]+)\x60|“([A-Za-z][^”\n]*)”"#)
    let markdown: String
    let ranges: [NSRange]

    init(answer: String, reference: AssistantQuestionReference?) {
        guard let reference, reference.source != nil else {
            markdown = answer
            ranges = []
            return
        }

        let original = answer as NSString
        let result = NSMutableString(string: answer)
        var locations: [NSRange] = []
        for match in Self.quotes.matches(in: answer, range: NSRange(location: 0, length: original.length)).reversed() {
            let captured = match.range(at: 1)
            let quote = original.substring(with: captured.location == NSNotFound ? match.range(at: 2) : captured)
            guard let range = reference.linkRange(for: quote),
                  !quote.contains("[") && !quote.contains("]") else { continue }
            result.replaceCharacters(in: match.range, with: "[`\(quote)`](smartread-quote:\(locations.count))")
            locations.append(range)
        }
        markdown = result as String
        ranges = locations
    }

    func location(for url: URL) -> NSRange? {
        guard url.scheme == "smartread-quote", let index = Int(url.absoluteString.dropFirst("smartread-quote:".count)),
              ranges.indices.contains(index) else { return nil }
        return ranges[index]
    }
}
