import Foundation

struct SRTParseResult: Equatable, Sendable {
    let cues: [SubtitleCue]
    let skippedBlockCount: Int
}

enum SRTParserError: LocalizedError, Equatable {
    case unsupportedEncoding
    case noValidCues

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "字幕文件不是受支持的 UTF-8 或 UTF-16 编码。"
        case .noValidCues:
            return "字幕文件中没有可用的 SRT 条目。"
        }
    }
}

enum SRTParser {
    static func parse(data: Data) throws -> SRTParseResult {
        guard let source = decode(data: data) else {
            throw SRTParserError.unsupportedEncoding
        }

        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(
            separatedBy: try NSRegularExpression(pattern: #"\n[ \t]*\n+"#)
        )

        var cues: [SubtitleCue] = []
        var skipped = 0

        for block in blocks {
            let lines = block
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .drop(while: \.isEmpty)

            guard !lines.isEmpty,
                  let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let interval = parseInterval(String(lines[timingIndex])) else {
                if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    skipped += 1
                }
                continue
            }

            let textLines = lines.dropFirst(lines.distance(from: lines.startIndex, to: timingIndex) + 1)
            let text = cleanText(textLines.joined(separator: "\n"))

            guard !text.isEmpty, interval.end > interval.start else {
                skipped += 1
                continue
            }

            cues.append(
                SubtitleCue(
                    startMilliseconds: interval.start,
                    endMilliseconds: interval.end,
                    text: text
                )
            )
        }

        guard !cues.isEmpty else {
            throw SRTParserError.noValidCues
        }

        cues.sort {
            if $0.startMilliseconds == $1.startMilliseconds {
                return $0.endMilliseconds < $1.endMilliseconds
            }
            return $0.startMilliseconds < $1.startMilliseconds
        }

        return SRTParseResult(cues: cues, skippedBlockCount: skipped)
    }

    private static func decode(data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }

        if let encoding = likelyBOMlessUTF16Encoding(data: data) {
            return String(data: data, encoding: encoding)
        }

        return String(data: data, encoding: .utf8)
    }

    private static func likelyBOMlessUTF16Encoding(data: Data) -> String.Encoding? {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return nil }

        let sample = data.prefix(256)
        var evenZeroCount = 0
        var oddZeroCount = 0

        for (index, byte) in sample.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) {
                evenZeroCount += 1
            } else {
                oddZeroCount += 1
            }
        }

        if oddZeroCount >= 2, oddZeroCount > evenZeroCount * 2 {
            return .utf16LittleEndian
        }
        if evenZeroCount >= 2, evenZeroCount > oddZeroCount * 2 {
            return .utf16BigEndian
        }
        return nil
    }

    private static func parseInterval(_ line: String) -> (start: Int64, end: Int64)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0]),
              let endToken = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace)
                .first,
              let end = parseTimestamp(String(endToken)) else {
            return nil
        }
        return (start, end)
    }

    private static func parseTimestamp(_ rawValue: String) -> Int64? {
        let value = rawValue
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let timeParts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard timeParts.count == 3,
              let hours = Int64(timeParts[0]), (0...9_999).contains(hours),
              let minutes = Int64(timeParts[1]),
              minutes >= 0, minutes < 60 else {
            return nil
        }

        let secondParts = timeParts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count == 2,
              let seconds = Int64(secondParts[0]),
              seconds >= 0, seconds < 60 else {
            return nil
        }

        let fraction = String(secondParts[1])
        guard (1...3).contains(fraction.count),
              let rawMilliseconds = Int64(fraction), rawMilliseconds >= 0 else {
            return nil
        }

        let milliseconds: Int64
        switch fraction.count {
        case 1:
            milliseconds = rawMilliseconds * 100
        case 2:
            milliseconds = rawMilliseconds * 10
        default:
            milliseconds = rawMilliseconds
        }

        return ((hours * 60 + minutes) * 60 + seconds) * 1_000 + milliseconds
    }

    private static func cleanText(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        if let expression = try? NSRegularExpression(pattern: #"<[^>]+>"#) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = expression.stringByReplacingMatches(
                in: cleaned,
                range: range,
                withTemplate: ""
            )
        }

        return cleaned
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        let fullRange = NSRange(startIndex..<endIndex, in: self)
        var result: [String] = []
        var previousEnd = startIndex

        for match in expression.matches(in: self, range: fullRange) {
            guard let range = Range(match.range, in: self) else { continue }
            result.append(String(self[previousEnd..<range.lowerBound]))
            previousEnd = range.upperBound
        }

        result.append(String(self[previousEnd..<endIndex]))
        return result
    }
}
