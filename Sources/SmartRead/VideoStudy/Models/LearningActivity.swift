import CryptoKit
import Foundation

enum LearningActivityKind: String, Codable, Sendable {
    case word
    case sentence
}

enum LearningActivityStatus: String, Codable, Sendable {
    case pending
    case completed
    case failed
    case interrupted
}

struct LearningActivityDraft: Sendable {
    let kind: LearningActivityKind
    let videoURL: URL
    let english: String
    let chinese: String
    let previousEnglish: String?
    let nextEnglish: String?
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    var word: SubtitleWord? = nil
    var sourceStartMilliseconds: Int64? = nil
    var englishOffsetMilliseconds: Int64? = nil
    var chineseOffsetMilliseconds: Int64? = nil
    var sourceContext: SubtitleSentenceContext? = nil
    var englishTrackKey: String? = nil
    var englishTiming: SubtitleTrackTiming? = nil
    var chineseTiming: SubtitleTrackTiming? = nil

    var identity: String {
        let values = [kind.rawValue, videoURL.standardizedFileURL.path,
                      String(sourceStartMilliseconds ?? startMilliseconds), english, word?.text ?? "",
                      word.map { String($0.range.location) } ?? ""]
        return SHA256.hash(data: Data(values.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct LearningActivity: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let dayKey: String
    let timeZoneIdentifier: String
    let kind: LearningActivityKind
    let identity: String
    let videoPath: String
    let english: String
    let chinese: String
    let previousEnglish: String?
    let nextEnglish: String?
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let word: String?
    let wordStartUTF16: Int?
    let wordLengthUTF16: Int?
    let firstTriggeredAt: Date
    var lastTriggeredAt: Date
    var interactionCount: Int
    var generation: Int
    var status: LearningActivityStatus
    var modelID: String
    var wordExplanation: WordExplanation?
    var sentenceAnalysis: SentenceAnalysis?
    var errorMessage: String?
    var lastSucceededAt: Date? = nil
    var lastSucceededModelID: String? = nil
    var sourceStartMilliseconds: Int64? = nil
    var englishOffsetMilliseconds: Int64? = nil
    var chineseOffsetMilliseconds: Int64? = nil
    var validationVersion: String? = nil
    var sourceContext: SubtitleSentenceContext? = nil
    var englishTiming: SubtitleTrackTiming? = nil
    var chineseTiming: SubtitleTrackTiming? = nil
    /// Nil for historical automatic entries. Only an explicit confirmation
    /// makes a record eligible for future Obsidian writes.
    var confirmedAt: Date? = nil
    /// The directory authorized when the user confirmed this result.
    var exportDestination: String? = nil

    var handle: LearningActivityHandle {
        LearningActivityHandle(id: id, generation: generation, dayKey: dayKey)
    }
}

struct LearningActivityHandle: Equatable, Sendable {
    let id: UUID
    let generation: Int
    let dayKey: String
}

enum LearningDay {
    static func key(for date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
