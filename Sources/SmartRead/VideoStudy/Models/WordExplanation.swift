import Foundation

struct SubtitleWord: Equatable, Sendable {
    let text: String
    let range: NSRange
}

enum SubtitleWordTokenizer {
    // Keep contractions and hyphenated words together; punctuation and spaces
    // are never click targets. Ranges match TextKit's UTF-16 indexing.
    static func words(in text: String) -> [SubtitleWord] {
        let source = text as NSString
        return WordLookup.pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { SubtitleWord(text: source.substring(with: $0.range), range: $0.range) }
    }

    // Phrase ranges start/end at complete visible words. Never accept arbitrary
    // or stale UTF-16 ranges supplied by a mouse event or model response.
    static func selection(in text: String, from first: SubtitleWord, to last: SubtitleWord) -> SubtitleWord? {
        let tokens = words(in: text)
        guard tokens.contains(first), tokens.contains(last) else { return nil }
        let start = min(first.range.location, last.range.location)
        let end = max(NSMaxRange(first.range), NSMaxRange(last.range))
        let range = NSRange(location: start, length: end - start)
        let value = (text as NSString).substring(with: range)
        guard range.length <= 160, tokens.filter({ NSIntersectionRange($0.range, range).length > 0 }).count <= 8,
              !value.contains(where: { $0.isNewline }) else { return nil }
        return SubtitleWord(text: value, range: range)
    }

    static func isValidTarget(_ target: SubtitleWord, in text: String) -> Bool {
        let tokens = words(in: text)
        guard let first = tokens.first(where: { $0.range.location == target.range.location }),
              let last = tokens.last(where: { NSMaxRange($0.range) == NSMaxRange(target.range) }) else { return false }
        return selection(in: text, from: first, to: last) == target
    }
}

struct WordLookupRequest: Equatable, Sendable {
    let word: SubtitleWord
    let sentence: String
    let chinese: String
    let previousEnglish: String?
    let nextEnglish: String?
    var sourceContext: SubtitleSentenceContext? = nil
}

struct WordExplanation: Codable, Equatable, Sendable {
    let lemma: String
    let partOfSpeechZh: String
    let meaningZh: String
    let usageNoteZh: String
    let exampleEnglish: String
    let exampleChinese: String

    var isValid: Bool {
        [lemma, partOfSpeechZh, meaningZh, usageNoteZh, exampleEnglish, exampleChinese]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum WordExampleQuality {
    static func issues(in explanation: WordExplanation) -> [String] {
        var issues: [String] = []
        if !explanation.exampleChinese.unicodeScalars.contains(where: {
            (0x3400...0x9FFF).contains($0.value)
        }) {
            issues.append("exampleChinese 必须是英文例句的简体中文翻译。")
        }
        if explanation.exampleEnglish.unicodeScalars.contains(where: {
            (0x3400...0x9FFF).contains($0.value)
        }) {
            issues.append("exampleEnglish 必须是英文例句，不要混入中文。")
        }
        let englishNumbers = numbers(in: explanation.exampleEnglish)
        let chineseNumbers = numbers(in: explanation.exampleChinese)
        // Only explicit conflicting digits are certain. "2 books / 两本书",
        // Chinese pronoun omission and sibling terminology need interpretation,
        // so they must not be used as automatic rejection rules.
        if !englishNumbers.isEmpty, !chineseNumbers.isEmpty, englishNumbers != chineseNumbers {
            issues.append("例句两种语言中的数字不一致，请让数字对应。")
        }
        return issues
    }

    private static func numbers(in text: String) -> [String] {
        let pattern = #"[0-9]+(?:[,，][0-9]{3})*(?:\.[0-9]+)?|\.[0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map {
                let number = source.substring(with: $0.range)
                    .replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: "，", with: "")
                return NSDecimalNumber(string: number, locale: Locale(identifier: "en_US_POSIX")).stringValue
            }
            .sorted()
    }
}

enum WordLookupState: Equatable {
    case idle
    case loading
    case loaded(WordExplanation)
    case failed(String)
}

protocol WordLookupServiceProtocol: Sendable {
    func lookupWord(
        request: WordLookupRequest,
        baseURL: String,
        modelID: String
    ) async throws -> WordExplanation
}
