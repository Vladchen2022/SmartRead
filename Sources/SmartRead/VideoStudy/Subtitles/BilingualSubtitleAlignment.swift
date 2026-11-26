import Foundation

/// A time-based association, not a translation or semantic sentence matcher.
/// One Chinese source cue has one primary English group, avoiding boundary
/// slivers importing the preceding/following speaker's entire translation.
struct BilingualSubtitleAlignment {
    private let chineseByGroup: [UUID: [SubtitleCue]]
    private let groupsByCue: [UUID: SubtitleSentenceContext]
    private let englishTiming: SubtitleTrackTiming
    private let chineseTiming: SubtitleTrackTiming

    init(groups: [SubtitleSentenceContext], chineseCues: [SubtitleCue],
         englishOffset: Int64 = 0, chineseOffset: Int64 = 0) {
        self.init(groups: groups, chineseCues: chineseCues, englishTiming: .init(offset: englishOffset),
                  chineseTiming: .init(offset: chineseOffset))
    }

    init(groups: [SubtitleSentenceContext], chineseCues: [SubtitleCue],
         englishTiming: SubtitleTrackTiming, chineseTiming: SubtitleTrackTiming) {
        self.englishTiming = englishTiming
        self.chineseTiming = chineseTiming
        var markers: [SubtitleCue] = []
        var groupByID: [UUID: SubtitleSentenceContext] = [:]
        var ordinal: [UUID: Int] = [:]
        var byCue: [UUID: SubtitleSentenceContext] = [:]
        for (index, group) in groups.enumerated() {
            guard let first = group.cues.first, let last = group.cues.last else { continue }
            markers.append(SubtitleCue(id: first.id, startMilliseconds: first.startMilliseconds,
                endMilliseconds: last.endMilliseconds, text: ""))
            groupByID[first.id] = group
            ordinal[first.id] = index
            for cue in group.cues { byCue[cue.id] = group }
        }
        let timeline = SubtitleTimeline(cues: markers)
        var aligned: [UUID: [SubtitleCue]] = [:]
        var seen: Set<UUID> = []
        for cue in SubtitleTimeline(cues: chineseCues).allCues where seen.insert(cue.id).inserted {
            let start = englishTiming.sourceTime(chineseTiming.videoTime(cue.startMilliseconds))
            let end = englishTiming.sourceTime(chineseTiming.videoTime(cue.endMilliseconds))
            let candidates = timeline.cues(overlappingStart: start, end: end)
            let owner = candidates.max { left, right in
                let a = min(left.endMilliseconds, end) - max(left.startMilliseconds, start)
                let b = min(right.endMilliseconds, end) - max(right.startMilliseconds, start)
                if a != b { return a < b }
                let da = abs((left.startMilliseconds + left.endMilliseconds) - (start + end))
                let db = abs((right.startMilliseconds + right.endMilliseconds) - (start + end))
                if da != db { return da > db }
                return (ordinal[left.id] ?? 0) > (ordinal[right.id] ?? 0)
            }
            if let owner, groupByID[owner.id] != nil { aligned[owner.id, default: []].append(cue) }
        }
        chineseByGroup = aligned
        groupsByCue = byCue
    }

    func cues(for group: SubtitleSentenceContext) -> [SubtitleCue] {
        guard let id = group.cues.first?.id else { return [] }
        return chineseByGroup[id] ?? []
    }

    func text(for group: SubtitleSentenceContext) -> String { cues(for: group).map(\.text).joined(separator: " ") }

    /// Word/transcript sources can be a subset of a reading group. Preserve
    /// whole Chinese source blocks, but never borrow from another English group.
    func cues(forEnglishCues selected: [SubtitleCue]) -> [SubtitleCue] {
        let selectedIDs = Set(selected.map(\.id))
        var seenGroups: Set<UUID> = [], seenChinese: Set<UUID> = []
        var result: [SubtitleCue] = []
        for cue in selected {
            guard let group = groupsByCue[cue.id], let id = group.cues.first?.id,
                  seenGroups.insert(id).inserted else { continue }
            let wholeGroup = group.cues.allSatisfy { selectedIDs.contains($0.id) }
            for chinese in cues(for: group) {
                let start = englishTiming.sourceTime(chineseTiming.videoTime(chinese.startMilliseconds))
                let end = englishTiming.sourceTime(chineseTiming.videoTime(chinese.endMilliseconds))
                if wholeGroup || selected.contains(where: { $0.startMilliseconds < end && start < $0.endMilliseconds }) {
                    if seenChinese.insert(chinese.id).inserted { result.append(chinese) }
                }
            }
        }
        return SubtitleTimeline(cues: result).allCues
    }
}
