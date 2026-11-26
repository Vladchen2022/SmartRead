import Foundation

struct LearningArticleSource: Codable, Equatable, Sendable {
    let sourceId: String
    let readingDate: String
    let course: String?
    let lesson: String?
    let titleZh: String?
    let path: String?
}

enum LearningArticleInput {
    static func parse(_ text: String, relativePath: String?) throws -> Article? {
        let normalized = Article.normalizedBody(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return nil }
        let end = lines.dropFirst().firstIndex(of: "---")
        let header = lines[1..<(end ?? lines.endIndex)]
        guard header.contains(where: { field($0)?.key == "smartreadFormat" }) else { return nil }
        guard let end else { throw invalid("缺少结束分隔线 ---。") }

        var fields: [String: String] = [:]
        for line in header where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let (key, value) = field(line), fields[key] == nil else {
                throw invalid("头部包含无效或重复字段。")
            }
            fields[key] = value
        }
        guard fields["smartreadFormat"] == "1" else { throw invalid("smartreadFormat 应为 1。") }

        func string(_ key: String, required: Bool = false) throws -> String? {
            guard let value = fields[key] else {
                if required { throw invalid("缺少 \(key)。") }
                return nil
            }
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)),
                  !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("\(key) 应为双引号内的非空字符串。")
            }
            return decoded
        }

        guard let title = try string("title", required: true),
              let sourceId = try string("sourceId", required: true),
              let date = try string("readingDate", required: true), validDate(date) else {
            throw invalid("readingDate 应为 YYYY-MM-DD 格式的有效日期。")
        }
        let source = LearningArticleSource(sourceId: sourceId, readingDate: date, course: try string("course"),
                                           lesson: try string("lesson"), titleZh: try string("titleZh"), path: relativePath)
        return try Article(title: title, body: lines[(end + 1)...].joined(separator: "\n"), learningSource: source)
    }

    private static func field(_ line: Substring) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return (line[..<colon].trimmingCharacters(in: .whitespaces),
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func validDate(_ date: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date).map { formatter.string(from: $0) == date } ?? false
    }

    private static func invalid(_ detail: String) -> ReaderError {
        .message("SmartRead 导入头无效。\(detail)")
    }
}
