import CryptoKit
import Foundation

struct SubtitleTrackTiming: Codable, Equatable, Sendable {
    var offset: Int64 = 0
    var origin: Int64 = 0
    var scale: Double = 1
    var isValid: Bool {
        (-SubtitleCalibration.limit...SubtitleCalibration.limit).contains(offset)
            && (0...360_000_000).contains(origin) && (0.8...1.25).contains(scale)
    }

    func videoTime(_ source: Int64) -> Int64 {
        Int64((Double(origin + offset) + Double(source - origin) * scale).rounded())
    }

    func sourceTime(_ video: Int64) -> Int64 {
        Int64((Double(origin) + Double(video - origin - offset) / scale).rounded())
    }

    init(offset: Int64 = 0) { self.offset = offset }

    init?(first: SubtitleTimingAnchor, second: SubtitleTimingAnchor) {
        let sourceDelta = second.source - first.source
        let videoDelta = second.video - first.video
        guard sourceDelta >= 1_000, videoDelta > 0 else { return nil }
        let rate = Double(videoDelta) / Double(sourceDelta)
        let offset = first.video - first.source
        guard (0.8...1.25).contains(rate), abs(offset) <= SubtitleCalibration.limit else { return nil }
        self.offset = offset
        origin = first.source
        scale = rate
    }
}

struct SubtitleTimingAnchor: Equatable, Sendable {
    let source: Int64
    let video: Int64
}

enum SubtitleBoundaryDecision: String, Codable, Sendable {
    case split, join
}

struct SubtitleTrackPreferences: Codable {
    var timing = SubtitleTrackTiming()
    var boundaries: [String: SubtitleBoundaryDecision] = [:]

    static func key(videoIdentity: String, language: SubtitleLanguage, cues: [SubtitleCue]) -> String {
        let content = cues.map { "\($0.startMilliseconds):\($0.endMilliseconds):\($0.text.utf8.count):\($0.text)" }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        return "subtitleTrack.v1.\(videoIdentity).\(language).\(digest)"
    }
}

struct SubtitleCalibration: Codable, Equatable, Sendable {
    var englishMilliseconds: Int64 = 0
    var chineseMilliseconds: Int64 = 0
    private var englishDrift: SubtitleTrackTiming?
    private var chineseDrift: SubtitleTrackTiming?
    static let limit: Int64 = 60_000

    static func storageKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "subtitleCalibration.\(digest)"
    }
    func offset(for language: SubtitleLanguage) -> Int64 {
        language == .english ? englishMilliseconds : chineseMilliseconds
    }
    func timing(for language: SubtitleLanguage) -> SubtitleTrackTiming {
        var result = (language == .english ? englishDrift : chineseDrift) ?? SubtitleTrackTiming()
        result.offset = max(-Self.limit, min(Self.limit, offset(for: language)))
        return result.isValid ? result : SubtitleTrackTiming(offset: result.offset)
    }
    mutating func apply(_ timing: SubtitleTrackTiming, for language: SubtitleLanguage) {
        guard timing.isValid else { return }
        set(timing.offset, for: language)
        if language == .english { englishDrift = timing }
        else { chineseDrift = timing }
    }
    mutating func set(_ value: Int64, for language: SubtitleLanguage) {
        let bounded = max(-Self.limit, min(Self.limit, value))
        if language == .english { englishMilliseconds = bounded }
        else { chineseMilliseconds = bounded }
    }
}

enum SubtitleRevealStage: Int, Sendable {
    case hidden, english, bilingual
    var next: Self { Self(rawValue: min(2, rawValue + 1)) ?? .bilingual }
    var title: String {
        switch self {
        case .hidden: "显示英文"
        case .english: "显示中文"
        case .bilingual: "重新隐藏"
        }
    }
    var stageTitle: String {
        switch self {
        case .hidden: "盲听"
        case .english: "英文"
        case .bilingual: "双语"
        }
    }
}

enum SubtitleTimeLabel {
    static func string(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1_000
        return seconds >= 3_600
            ? String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
