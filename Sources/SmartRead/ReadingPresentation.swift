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

    func originalCharacter(at displayed: Int) -> Int? {
        if displayed < insertion { return displayed }
        if displayed < insertion + displayLength { return nil }
        return displayed - displayLength
    }

    func originalBoundary(at displayed: Int) -> Int {
        originalCharacter(at: displayed) ?? insertion
    }

    func originalRange(for displayed: NSRange) -> NSRange {
        let start = originalBoundary(at: displayed.location)
        let end = originalBoundary(at: NSMaxRange(displayed))
        return NSRange(location: start, length: end - start)
    }

    func displayedRange(for original: NSRange) -> NSRange {
        let startsAfter = original.location >= insertion
        let endsAfter = NSMaxRange(original) > insertion || (startsAfter && original.length == 0)
        let start = original.location + (startsAfter ? displayLength : 0)
        let end = NSMaxRange(original) + (endsAfter ? displayLength : 0)
        return NSRange(location: start, length: end - start)
    }

    func displayedSegments(for original: NSRange) -> [NSRange] {
        let end = NSMaxRange(original)
        guard original.location < insertion, end > insertion else { return [displayedRange(for: original)] }
        return [
            NSRange(location: original.location, length: insertion - original.location),
            NSRange(location: insertion + displayLength, length: end - insertion)
        ]
    }
}
