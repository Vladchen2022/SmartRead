import Foundation

struct SubtitleTimeline: Sendable {
    private let cues: [SubtitleCue]
    private let prefixMaximumEnd: [Int64]

    init(cues: [SubtitleCue]) {
        self.cues = cues.sorted {
            if $0.startMilliseconds == $1.startMilliseconds {
                return $0.endMilliseconds < $1.endMilliseconds
            }
            return $0.startMilliseconds < $1.startMilliseconds
        }

        var maximum: Int64 = .min
        self.prefixMaximumEnd = self.cues.map {
            maximum = max(maximum, $0.endMilliseconds)
            return maximum
        }
    }

    var allCues: [SubtitleCue] {
        cues
    }

    func activeCues(at milliseconds: Int64) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }

        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].startMilliseconds <= milliseconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var index = lower - 1
        var active: [SubtitleCue] = []
        while index >= 0 {
            if prefixMaximumEnd[index] <= milliseconds {
                break
            }
            let cue = cues[index]
            if cue.startMilliseconds <= milliseconds,
               milliseconds < cue.endMilliseconds {
                active.append(cue)
            }
            index -= 1
        }

        return active.reversed()
    }

    func context(around activeCues: [SubtitleCue]) -> (previous: String?, next: String?) {
        guard let first = activeCues.first,
              let last = activeCues.last,
              let firstIndex = cues.firstIndex(where: { $0.id == first.id }),
              let lastIndex = cues.firstIndex(where: { $0.id == last.id }) else {
            return (nil, nil)
        }

        // Do not feed unrelated scenes/credits as conversational context. Keep
        // source blocks verbatim, including speaker breaks; never invent joins.
        let previous = firstIndex > 0 && first.startMilliseconds - cues[firstIndex - 1].endMilliseconds <= 8_000
            ? cues[firstIndex - 1].text : nil
        let next = lastIndex + 1 < cues.count && cues[lastIndex + 1].startMilliseconds - last.endMilliseconds <= 8_000
            ? cues[lastIndex + 1].text : nil
        return (previous, next)
    }

    /// All genuine interval intersections, start-inclusive/end-exclusive.
    /// Midpoint sampling loses short translations within a long source cue.
    func cues(overlappingStart start: Int64, end: Int64) -> [SubtitleCue] {
        guard start < end, !cues.isEmpty else { return [] }
        var lower = 0, upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].startMilliseconds < end { lower = middle + 1 }
            else { upper = middle }
        }
        var index = lower - 1
        var result: [SubtitleCue] = []
        while index >= 0 {
            if prefixMaximumEnd[index] <= start { break }
            let cue = cues[index]
            if cue.endMilliseconds > start, cue.startMilliseconds < end { result.append(cue) }
            index -= 1
        }
        return result.reversed()
    }

    func previousCue(at milliseconds: Int64) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }

        let active = activeCues(at: milliseconds)
        if let firstActive = active.first,
           let activeIndex = cues.firstIndex(where: { $0.id == firstActive.id }) {
            return activeIndex > 0 ? cues[activeIndex - 1] : nil
        }

        let insertionIndex = firstCueIndex(startingAtOrAfter: milliseconds)
        return insertionIndex > 0 ? cues[insertionIndex - 1] : nil
    }

    func nextCue(at milliseconds: Int64) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }

        let active = activeCues(at: milliseconds)
        if let lastActive = active.last,
           let activeIndex = cues.firstIndex(where: { $0.id == lastActive.id }) {
            let nextIndex = activeIndex + 1
            return nextIndex < cues.count ? cues[nextIndex] : nil
        }

        let insertionIndex = firstCueIndex(startingAfter: milliseconds)
        return insertionIndex < cues.count ? cues[insertionIndex] : nil
    }

    private func firstCueIndex(startingAtOrAfter milliseconds: Int64) -> Int {
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].startMilliseconds < milliseconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func firstCueIndex(startingAfter milliseconds: Int64) -> Int {
        var lower = 0
        var upper = cues.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].startMilliseconds <= milliseconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
