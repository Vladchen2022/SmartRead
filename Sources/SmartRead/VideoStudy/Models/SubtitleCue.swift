import Foundation

struct SubtitleCue: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String

    init(
        id: UUID = UUID(),
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        text: String
    ) {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
    }
}

struct SubtitleSelection: Equatable, Sendable {
    let english: String
    let chinese: String
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let previousEnglish: String?
    let nextEnglish: String?
    let videoURL: URL?
    var sourceContext: SubtitleSentenceContext? = nil
    var rawStartMilliseconds: Int64? = nil
    var englishTiming: SubtitleTrackTiming? = nil
    var chineseTiming: SubtitleTrackTiming? = nil
    var englishTrackKey: String? = nil
}
