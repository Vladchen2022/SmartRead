import Foundation

enum StoredSubtitleKind: String, Sendable {
    case automatic
    case embedded
    case external
    case none
}

struct VideoLearningRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let displayName: String
    let durationMilliseconds: Int64
    let lastPositionMilliseconds: Int64
    let totalWatchedMilliseconds: Int64
    let playbackRate: Double
    let selectedAudioTrackID: Int32?
    let englishSubtitleKind: StoredSubtitleKind
    let englishSubtitlePath: String?
    let englishSubtitleTrackID: Int?
    let chineseSubtitleKind: StoredSubtitleKind
    let chineseSubtitlePath: String?
    let chineseSubtitleTrackID: Int?
    let createdAt: Date
    let lastOpenedAt: Date
    let updatedAt: Date

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var sourceExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var progress: Double {
        guard durationMilliseconds > 0 else { return 0 }
        return min(
            1,
            max(
                0,
                Double(lastPositionMilliseconds)
                    / Double(durationMilliseconds)
            )
        )
    }
}

struct VideoLearningStateDraft: Equatable, Sendable {
    let videoURL: URL
    let displayName: String
    let durationMilliseconds: Int64
    let lastPositionMilliseconds: Int64
    let totalWatchedMilliseconds: Int64
    let playbackRate: Double
    let selectedAudioTrackID: Int32?
    let englishSubtitleKind: StoredSubtitleKind
    let englishSubtitlePath: String?
    let englishSubtitleTrackID: Int?
    let chineseSubtitleKind: StoredSubtitleKind
    let chineseSubtitlePath: String?
    let chineseSubtitleTrackID: Int?
}
