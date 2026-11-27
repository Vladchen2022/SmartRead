import Foundation

struct WeeklyFavoritePeriod: Sendable {
    var calendar: Calendar

    init(timeZone: TimeZone = .current) {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
    }

    func week(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    func label(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

struct WeeklyFavoriteOrigin: Codable, Equatable, Sendable {
    let sourceID: String
    let title: String
    let webURL: URL?
    let pdfLocation: String?

    init(record: LearningRecord, range: NSRange, webURL: URL? = nil) {
        if let page = record.pdfPage {
            self = Self(page: page, range: range, webURL: record.importedWebURL ?? webURL)
        } else {
            sourceID = record.articleId.uuidString.lowercased()
            title = record.title
            self.webURL = record.importedWebURL ?? webURL
            pdfLocation = nil
        }
    }

    init(page: PDFBookLocation, range: NSRange, webURL: URL? = nil) {
        sourceID = "pdf:" + page.book.id
        title = page.book.title
        self.webURL = webURL
        let label = "PDF 第 \(page.sourcePage(at: range.location) + 1) 页"
        pdfLocation = page.chapter.map { "\($0.chapter.label) · \(label)" } ?? label
    }
}

struct WeeklyFavoriteJob: Codable, Sendable {
    var favorite: LearningFavorite?
    var question: AssistantQuestionFavorite?
    let recordFile: URL
    var folder: URL
    let weekStart: String
    let day: String
    let sourceID: String
    let title: String
    let webURL: URL?
    let pdfLocation: String?

    init(favorite: LearningFavorite, record: LearningRecord, recordFile: URL, folder: URL,
         period: WeeklyFavoritePeriod, webURL: URL? = nil) {
        let range = NSRange(location: favorite.range.location, length: favorite.range.length)
        self.init(favorite: favorite, question: nil, date: favorite.createdAt, recordFile: recordFile,
                  folder: folder, period: period, origin: .init(record: record, range: range, webURL: webURL))
    }

    init(question: AssistantQuestionFavorite, origin: WeeklyFavoriteOrigin, recordFile: URL, folder: URL,
         period: WeeklyFavoritePeriod) {
        self.init(favorite: nil, question: question, date: question.savedAt, recordFile: recordFile,
                  folder: folder, period: period, origin: origin)
    }

    private init(favorite: LearningFavorite?, question: AssistantQuestionFavorite?, date: Date, recordFile: URL,
                 folder: URL, period: WeeklyFavoritePeriod, origin: WeeklyFavoriteOrigin) {
        self.favorite = favorite
        self.question = question
        self.recordFile = recordFile
        self.folder = folder
        weekStart = period.label(for: period.week(containing: date).start)
        day = period.label(for: date)
        sourceID = origin.sourceID
        title = origin.title
        webURL = origin.webURL
        pdfLocation = origin.pdfLocation
    }

    var hasOneFavorite: Bool { (favorite != nil) != (question != nil) }
    var date: Date { favorite?.createdAt ?? question?.savedAt ?? .distantPast }
    var favoriteID: String { favorite?.id ?? question?.weeklyID ?? "" }
    var noteURL: URL { folder.appending(path: "\(weekStart) 英语泛读沉淀.md") }
    var entryID: String { LearningRecord.fingerprint(favoriteID) }
    var id: String { noteURL.path + "\n" + entryID }
}

enum WeeklyFavoriteNotes {
    private enum WriteError: LocalizedError {
        case unavailable, unsafeNote, changed, missingMarker

        var errorDescription: String? {
            switch self {
            case .unavailable: "收藏目录不存在或无法访问。"
            case .unsafeNote: "同名周记不是普通 Markdown 文件。"
            case .changed: "周记正在被修改，请重试。"
            case .missingMarker: "周记中的来源标记不完整，请恢复标记后重试。"
            }
        }
    }

    static func directory(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.isFileURL,
              try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw WriteError.unavailable
        }
        return resolved
    }

    @discardableResult
    static func append(_ jobs: [WeeklyFavoriteJob], to url: URL) throws -> Int {
        guard let first = jobs.first else { return 0 }
        let folder = url.deletingLastPathComponent()
        guard try directory(folder).path == folder.path else { throw WriteError.unavailable }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Int, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            result = Result {
                let original = try readNote(coordinatedURL)
                var updated = original ?? "# \(first.weekStart) 英语泛读沉淀\n"
                var appended = 0
                for job in jobs.sorted(by: {
                    $0.date == $1.date ? $0.entryID < $1.entryID : $0.date < $1.date
                }) {
                    if try insert(job, in: &updated) { appended += 1 }
                }
                guard appended > 0 else { return 0 }
                guard try readNote(coordinatedURL) == original else { throw WriteError.changed }
                try updated.write(to: coordinatedURL, atomically: true, encoding: .utf8)
                return appended
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw WriteError.unavailable }
        return try result.get()
    }

    private static func readNote(_ url: URL) throws -> String? {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WriteError.unsafeNote }
            return try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func insert(_ job: WeeklyFavoriteJob, in note: inout String) throws -> Bool {
        let entryMarker = "<!-- smartread-favorite:\(job.entryID) -->"
        guard !note.contains(entryMarker) else { return false }

        let sourceID = LearningRecord.fingerprint(job.sourceID)
        let start = "<!-- smartread-source:\(sourceID) -->"
        let end = "<!-- /smartread-source:\(sourceID) -->"
        let entry = render(job, marker: entryMarker)
        switch (note.range(of: start), note.range(of: end)) {
        case (nil, nil):
            let title = job.title.components(separatedBy: .newlines).joined(separator: " ")
            var heading = "\n\n\(start)\n## \(escape(title))\n"
            if let url = job.webURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                heading += "\n来源 <\(url.absoluteString.replacingOccurrences(of: ">", with: "%3E"))>\n"
            }
            note += heading + "\n" + entry + "\n" + end + "\n"
        case let (start?, end?) where start.upperBound <= end.lowerBound:
            note.insert(contentsOf: "\n" + entry + "\n", at: end.lowerBound)
        default:
            throw WriteError.missingMarker
        }
        return true
    }

    private static func render(_ job: WeeklyFavoriteJob, marker: String) -> String {
        let location = job.pdfLocation.map { " · " + escape($0) } ?? ""
        if let question = job.question, let reference = question.reference {
            let fields = [("原句", reference.passage), ("问题", question.question), ("回答", question.answer)]
            return ([marker, "**\(job.day) · 问答\(location)**"] + fields.flatMap { title, text in
                ["", "**\(title)**", "", quote(text)]
            }).joined(separator: "\n") + "\n"
        }
        guard let favorite = job.favorite else { return "" }
        var lines = [marker, "**\(job.day) · \(favorite.kind.label)\(location)**", "", quote(favorite.displayQuote)]
        if favorite.sentence != favorite.selectedText, favorite.kind == .word || favorite.kind == .phrase {
            lines += ["", "例句", quote(favorite.sentence)]
        }
        for content in [favorite.result.definition, favorite.result.translation, favorite.result.analysis].compactMap({ $0 }) {
            lines += ["", quote(content)]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { "> " + escape($0) }.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "|", "#", "~", "$", "=", "!"]
        return text.reduce(into: "") { result, character in
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
