import Foundation

/// A bounded, source-verbatim span. This is conservative text segmentation,
/// not speaker recognition: unmarked speaker changes cannot be proven from SRT.
struct SubtitleSentenceContext: Codable, Equatable, Sendable {
    let cues: [SubtitleCue]
    var english: String { cues.map(\.text).joined(separator: " ") }

    /// A stable, non-overlapping partition for reading/navigation. Unlike a
    /// sliding context window, its boundaries do not move as the cue changes.
    static func boundaryKey(_ left: SubtitleCue, _ right: SubtitleCue) -> String {
        "\(left.startMilliseconds):\(left.endMilliseconds):\(right.startMilliseconds):\(right.endMilliseconds)"
    }

    static func groups(in cues: [SubtitleCue], boundaries: [String: SubtitleBoundaryDecision] = [:]) -> [Self] {
        let sorted = SubtitleTimeline(cues: cues).allCues
        var groups: [Self] = []
        var current: [SubtitleCue] = []
        for cue in sorted {
            if let last = current.last, current.count >= 6 || !canContinue(last, cue, boundaries: boundaries) {
                groups.append(Self(cues: current))
                current = []
            }
            current.append(cue)
        }
        if !current.isEmpty { groups.append(Self(cues: current)) }
        return groups
    }

    static func build(in all: [SubtitleCue], selected: [SubtitleCue], boundaries: [String: SubtitleBoundaryDecision] = [:]) -> Self? {
        guard let first = selected.first, let last = selected.last,
              let start = all.firstIndex(where: { $0.id == first.id }),
              let end = all.firstIndex(where: { $0.id == last.id }), start <= end else { return nil }
        // Overlapping active cues may be simultaneous dialogue, not one sentence.
        guard selected.count == 1 else { return Self(cues: selected) }
        var lower = start, upper = end
        while lower > 0, start - lower < 3,
              canContinue(all[lower - 1], all[lower], boundaries: boundaries) { lower -= 1 }
        while upper + 1 < all.count, upper - end < 3,
              upper - lower < 5, canContinue(all[upper], all[upper + 1], boundaries: boundaries) { upper += 1 }
        return Self(cues: Array(all[lower...upper]))
    }

    private static func canContinue(_ left: SubtitleCue, _ right: SubtitleCue, boundaries: [String: SubtitleBoundaryDecision]) -> Bool {
        let gap = right.startMilliseconds - left.endMilliseconds
        if let decision = boundaries[boundaryKey(left, right)] {
            // Never combine simultaneous subtitle blocks, even explicitly.
            return decision == .join && gap >= 0 && gap <= 8_000
        }
        guard gap >= 0, gap <= 1_500,
              !hasDialogueBreak(left.text), !hasDialogueBreak(right.text) else { return false }
        let a = speech(left.text), b = speech(right.text)
        guard !a.isEmpty, !b.isEmpty, !isStageDirection(left.text), !isStageDirection(right.text) else { return false }
        let leftSpeaker = speaker(left.text), rightSpeaker = speaker(right.text)
        // A new explicit label always starts a turn. Repeated identical labels
        // are allowed; an initial label can be followed by an unlabelled fragment.
        if let rightSpeaker, rightSpeaker != leftSpeaker { return false }
        let trimmed = a.trimmingCharacters(in: CharacterSet(charactersIn: "\"'’”)] "))
        guard !trimmed.hasSuffix("--"), !trimmed.hasSuffix("—"),
              ![".", "!", "?", "…"].contains(where: { trimmed.hasSuffix($0) }) else { return false }
        guard let first = b.first else { return false }
        if first.isASCII, first.isLetter, first.isLowercase { return true }
        if a.hasSuffix(",") { return true } // e.g. "When I arrived," / "I saw..."
        let lastWord = SubtitleWordTokenizer.words(in: a).last?.text.lowercased() ?? ""
        return ["a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "by", "from",
                "and", "or", "but", "that", "because", "if", "when", "while", "as", "than",
                "is", "are", "was", "were", "be", "been", "have", "has", "had", "will", "would",
                "can", "could", "my", "your", "his", "her", "our", "their"].contains(lastWord)
    }

    private static func hasDialogueBreak(_ value: String) -> Bool {
        value.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("-") || line.hasPrefix("–") || line.hasPrefix("—")
        } || value.components(separatedBy: .newlines).filter { speaker($0) != nil }.count > 1
    }

    private static func speaker(_ text: String) -> String? {
        let pattern = #"^\s*([A-Za-z][A-Za-z .'-]{0,30}):\s*"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[match].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func speech(_ value: String) -> String {
        value.replacingOccurrences(of: #"^\s*[A-Za-z][A-Za-z .'-]{0,30}:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isStageDirection(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")"))
    }
}
