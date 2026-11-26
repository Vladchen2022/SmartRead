import Foundation

enum EnglishReadingMode: String, CaseIterable, Identifiable {
    case original
    case sentence
    var id: String { rawValue }
    var title: String { self == .sentence ? "整句阅读" : "原始字幕" }
}

enum SubtitleReadingPhase: Equatable {
    case past, current, upcoming
}

struct SubtitleReadingSegment: Equatable {
    let cue: SubtitleCue
    let range: NSRange
    let phase: SubtitleReadingPhase
}

struct SubtitleReadingFrame: Equatable {
    let context: SubtitleSentenceContext
    let text: String
    let segments: [SubtitleReadingSegment]

    init(context: SubtitleSentenceContext, at milliseconds: Int64) {
        self.context = context
        text = context.english
        var offset = 0
        segments = context.cues.map { cue in
            let length = (cue.text as NSString).length
            defer { offset += length + 1 }
            let phase: SubtitleReadingPhase = milliseconds < cue.startMilliseconds ? .upcoming
                : milliseconds < cue.endMilliseconds ? .current : .past
            return SubtitleReadingSegment(cue: cue, range: NSRange(location: offset, length: length), phase: phase)
        }
    }

    /// Resolve a word/phrase back to its original cue(s), without seeking the
    /// player or mistaking a future fragment's timestamp for the current one.
    func source(for word: SubtitleWord) -> (word: SubtitleWord, cues: [SubtitleCue], text: String)? {
        guard SubtitleWordTokenizer.isValidTarget(word, in: text) else { return nil }
        let touched = segments.filter { NSIntersectionRange($0.range, word.range).length > 0 }
        guard let first = touched.first else { return nil }
        let source = touched.map(\.cue.text).joined(separator: " ")
        let local = SubtitleWord(text: word.text, range: NSRange(location: word.range.location - first.range.location, length: word.range.length))
        guard SubtitleWordTokenizer.isValidTarget(local, in: source) else { return nil }
        return (local, touched.map(\.cue), source)
    }
}

struct SubtitleReadingTimeline {
    let groups: [SubtitleSentenceContext]
    private let markerTimeline: SubtitleTimeline
    private let contexts: [UUID: SubtitleSentenceContext]

    init(cues: [SubtitleCue], boundaries: [String: SubtitleBoundaryDecision] = [:]) {
        groups = SubtitleSentenceContext.groups(in: cues, boundaries: boundaries)
        var markers: [SubtitleCue] = []
        var contexts: [UUID: SubtitleSentenceContext] = [:]
        for group in groups {
            guard let first = group.cues.first, let last = group.cues.last else { continue }
            markers.append(SubtitleCue(id: first.id, startMilliseconds: first.startMilliseconds, endMilliseconds: last.endMilliseconds, text: group.english))
            contexts[first.id] = group
        }
        markerTimeline = SubtitleTimeline(cues: markers)
        self.contexts = contexts
    }

    func frame(at milliseconds: Int64) -> SubtitleReadingFrame? {
        let active = markerTimeline.activeCues(at: milliseconds)
        // Simultaneous groups are ambiguous dialogue, not one merged utterance.
        guard active.count == 1, let marker = active.first, let context = contexts[marker.id] else { return nil }
        return SubtitleReadingFrame(context: context, at: milliseconds)
    }

    func previous(at milliseconds: Int64) -> SubtitleCue? { markerTimeline.previousCue(at: milliseconds) }
    func next(at milliseconds: Int64) -> SubtitleCue? { markerTimeline.nextCue(at: milliseconds) }
}
