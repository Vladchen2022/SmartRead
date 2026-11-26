import Foundation

/// A practice pass owns a fixed source span, independent of the moving clock.
/// Subtitle fragments and their short gaps cannot replace this sentence.
struct ListeningPractice: Equatable, Sendable {
    let context: SubtitleSentenceContext
    let startMilliseconds: Int64
    let endMilliseconds: Int64

    init?(context: SubtitleSentenceContext, offset: Int64, duration: Int64) {
        self.init(context: context, timing: SubtitleTrackTiming(offset: offset), duration: duration)
    }

    init?(context: SubtitleSentenceContext, timing: SubtitleTrackTiming, duration: Int64) {
        guard let first = context.cues.first, let last = context.cues.last else { return nil }
        let start = max(0, timing.videoTime(first.startMilliseconds))
        let sourceEnd = timing.videoTime(last.endMilliseconds)
        let end = duration > 0 ? min(duration, sourceEnd) : sourceEnd
        guard end > start else { return nil }
        self.context = context
        startMilliseconds = start
        endMilliseconds = end
    }
}
