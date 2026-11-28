import Foundation

struct InlineTranslation: Equatable {
    let sentence: NSRange
    let text: String

    var insertion: Int { NSMaxRange(sentence) }
    var displayText: String { "\n译文  \(text)  收起译文\n" }
    var displayLength: Int { displayText.utf16.count }

    var closeRange: NSRange {
        let close = "收起译文".utf16.count
        return NSRange(location: insertion + displayLength - close - 1, length: close)
    }
}

/// Maps the text view's inserted translations and figures back to the stable source text.
struct ReaderDisplayMap {
    struct Insertion {
        let sourceOffset: Int
        let displayRange: NSRange
    }

    let insertions: [Insertion]

    init(_ lengths: [(offset: Int, length: Int)]) {
        var added = 0
        insertions = lengths.map { item in
            let range = NSRange(location: item.offset + added, length: item.length)
            added += item.length
            return Insertion(sourceOffset: item.offset, displayRange: range)
        }
    }

    func sourceCharacter(at displayed: Int) -> Int? {
        if insertions.contains(where: { NSLocationInRange(displayed, $0.displayRange) }) { return nil }
        return sourceBoundary(at: displayed)
    }

    func sourceBoundary(at displayed: Int) -> Int {
        var added = 0
        for insertion in insertions {
            if displayed < insertion.displayRange.location { break }
            if NSLocationInRange(displayed, insertion.displayRange) { return insertion.sourceOffset }
            added += insertion.displayRange.length
        }
        return displayed - added
    }

    func sourceRange(for displayed: NSRange) -> NSRange {
        let start = sourceBoundary(at: displayed.location)
        return NSRange(location: start, length: sourceBoundary(at: NSMaxRange(displayed)) - start)
    }

    func displayedRange(for source: NSRange) -> NSRange {
        let start = displayedBoundary(source.location, after: true)
        let end = displayedBoundary(NSMaxRange(source), after: source.length == 0)
        return NSRange(location: start, length: end - start)
    }

    func displayedSegments(for source: NSRange) -> [NSRange] {
        let limit = NSMaxRange(source)
        var start = source.location
        var result: [NSRange] = []
        for insertion in insertions where insertion.sourceOffset > start && insertion.sourceOffset < limit {
            result.append(displayedRange(for: NSRange(location: start, length: insertion.sourceOffset - start)))
            start = insertion.sourceOffset
        }
        result.append(displayedRange(for: NSRange(location: start, length: limit - start)))
        return result
    }

    private func displayedBoundary(_ source: Int, after: Bool) -> Int {
        source + insertions.reduce(0) { length, item in
            length + (item.sourceOffset < source || (after && item.sourceOffset == source) ? item.displayRange.length : 0)
        }
    }
}
