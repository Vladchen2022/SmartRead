import XCTest
@testable import SmartRead

final class WeeklyFavoriteTests: XCTestCase {
    func testWeekUsesLocalMondayAcrossNewYear() throws {
        let period = WeeklyFavoritePeriod(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")))
        let parser = ISO8601DateFormatter()
        let sunday = try XCTUnwrap(parser.date(from: "2027-01-03T15:59:59Z"))
        let monday = try XCTUnwrap(parser.date(from: "2027-01-03T16:00:00Z"))
        XCTAssertEqual(period.label(for: period.week(containing: sunday).start), "2026-12-28")
        XCTAssertEqual(period.label(for: period.week(containing: monday).start), "2027-01-04")
    }

    @MainActor
    func testBackfillAppendsThisWeeksPDFAndTextWithoutRepeatingOrOverwritingNotes() async throws {
        let (root, defaults, store) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeFolder(WeeklyFavoriteSync.folderName, in: root)
        let courses = LearningRecordStore(projectRoot: root)
        let content = "She sat by the river."
        let input = try Article(title: "Imported Web Article", body: content, sourceURL: URL(string: "https://example.com/reading"))
        try store.save(ArticleLibrary(current: input))
        let activeReader = ReaderModel(defaults: defaults, store: store, learningStore: courses)
        try activeReader.saveFavorite(draft(content, "她坐在河边。"))

        let book = PDFBook(id: "book-id", title: "Love or Money?", pageCount: 42)
        let pdf = PDFBookLocation(book: book, index: 2, englishOnly: true, usedOCR: false, sentenceEnding: nil)
        let chapterPage = try Article(title: "Different Page Title", body: "It was the hottest day.", pdfPage: pdf)
        let imported = ImportedLearningRecords(root: store.importedLearningDirectory)
        let period = WeeklyFavoritePeriod()
        let weekStart = period.week(containing: .now).start
        var pdfRecord = LearningRecord(article: chapterPage, now: .now)
        let oldDate = weekStart.addingTimeInterval(-10)
        let range = NSRange(location: 0, length: chapterPage.body.utf16.count)
        pdfRecord.favorites = [
            .init(favoriteId: "last-week", kind: .grammar, selectedText: "Previous week example", sentence: "",
                  paragraph: 1, range: .init(range), result: .init(analysis: "Historical notes"), createdAt: oldDate, updatedAt: oldDate),
            .init(favoriteId: "this-week", kind: .sentence, selectedText: chapterPage.body, sentence: chapterPage.body,
                  paragraph: 1, range: .init(range), result: .init(translation: "那天最热。"), createdAt: .now, updatedAt: .now)
        ]
        try imported.save(pdfRecord, for: chapterPage)
        let url = folder.appending(path: "\(period.label(for: weekStart)) 英语泛读沉淀.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try "# 我的英语周记\n\n我的手写心得。\n".write(to: url, atomically: true, encoding: .utf8)

        activeReader.weeklyFavorites.setFolder(folder)
        activeReader.backfillWeeklyFavorites()
        try await wait(for: activeReader.weeklyFavorites)
        let first = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(first.hasPrefix("# 我的英语周记\n\n我的手写心得。\n"))
        XCTAssertTrue(first.contains("## Love or Money?"))
        XCTAssertTrue(first.contains("PDF 第 3 页"))
        XCTAssertTrue(first.contains("那天最热。"))
        XCTAssertTrue(first.contains("https://example.com/reading"))
        XCTAssertFalse(first.contains("Previous week example"))
        XCTAssertEqual(activeReader.weeklyFavorites.status, "已追加 2 条收藏。")

        activeReader.backfillWeeklyFavorites()
        try await wait(for: activeReader.weeklyFavorites)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first)
        XCTAssertEqual(activeReader.weeklyFavorites.status, "本周收藏已是最新。")
        try activeReader.removeFavorite(try XCTUnwrap(activeReader.favorites.first).id)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first)

        try activeReader.saveFavorite(.init(kind: .grammar, excerpt: draft(content, "").excerpt,
                                           result: .init(analysis: "过去式。")))
        try await wait(for: activeReader.weeklyFavorites)
        let appended = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(appended.contains("过去式。"))
        XCTAssertEqual(appended.components(separatedBy: "## Imported Web Article").count, 2)
        XCTAssertEqual(appended.components(separatedBy: "我的手写心得。").count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    @MainActor
    func testPendingRetrySurvivesRestartAndPreservesItsSelectedFolder() async throws {
        let (root, defaults, store) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFolder = try makeFolder("Old", in: root)
        let newFolder = try makeFolder("New", in: root)
        let courseStore = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(defaults: defaults, store: store, learningStore: courseStore)
        reader.weeklyFavorites.setFolder(oldFolder)
        try FileManager.default.removeItem(at: oldFolder)
        try reader.importText("Mary has an umbrella.", title: "First article")
        try reader.saveFavorite(draft(reader.article.body, "玛丽有一把伞。"))
        try await wait(for: reader.weeklyFavorites)
        XCTAssertEqual(reader.favorites.count, 1)
        XCTAssertEqual(reader.weeklyFavorites.pendingCount, 1)

        let restarted = ReaderModel(defaults: defaults, store: store, learningStore: courseStore)
        XCTAssertEqual(restarted.weeklyFavorites.pendingCount, 1)
        XCTAssertEqual(restarted.weeklyFavorites.folder?.path, oldFolder.path)
        restarted.weeklyFavorites.setAutomatic(false)
        restarted.weeklyFavorites.setFolder(newFolder)
        try restarted.importText("We went home.", title: "Second article")
        try restarted.saveFavorite(draft(restarted.article.body, "我们回家了。"))
        XCTAssertEqual(restarted.weeklyFavorites.pendingCount, 2)
        try restarted.removeFavorite(try XCTUnwrap(restarted.favorites.first).id)
        XCTAssertEqual(restarted.weeklyFavorites.pendingCount, 1)
        try restarted.saveFavorite(draft(restarted.article.body, "我们回家了。"))

        let course = root.appending(path: "Course.md")
        try """
        ---
        smartreadFormat: 1
        sourceId: "test.course.lesson"
        title: "Test Course"
        readingDate: "2026-11-25"
        ---
        It belongs to the course.
        """.write(to: course, atomically: true, encoding: .utf8)
        try restarted.importFile(course)
        try restarted.saveFavorite(draft(restarted.article.body, "课程收藏。"))
        XCTAssertEqual(restarted.weeklyFavorites.pendingCount, 2)

        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: false)
        restarted.weeklyFavorites.retry()
        try await wait(for: restarted.weeklyFavorites)
        XCTAssertEqual(restarted.weeklyFavorites.pendingCount, 0)
        let oldNote = try note(in: oldFolder)
        let newNote = try note(in: newFolder)
        XCTAssertTrue(oldNote.contains("玛丽有一把伞。"))
        XCTAssertTrue(newNote.contains("我们回家了。"))
        XCTAssertFalse(newNote.contains("玛丽有一把伞。"))
        XCTAssertFalse(newNote.contains("课程收藏。"))
    }

    @MainActor
    func testMovePendingToNewFolderSurvivesRestartAndBackfillDoesNotDuplicate() async throws {
        let (root, defaults, store) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeFolder("Old", in: root)
        let new = try makeFolder("New", in: root)
        let course = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(defaults: defaults, store: store, learningStore: course)
        reader.weeklyFavorites.setAutomatic(false)
        reader.weeklyFavorites.setFolder(old)
        try reader.importText("Bring a book.", title: "A lesson")
        try reader.saveFavorite(draft(reader.article.body, "带本书来。"))
        try FileManager.default.removeItem(at: old)
        reader.weeklyFavorites.setFolder(new, movingPending: true)
        let restarted = ReaderModel(defaults: defaults, store: store, learningStore: course)
        XCTAssertEqual(restarted.weeklyFavorites.previousDestinationCount, 0)
        XCTAssertEqual(restarted.weeklyFavorites.pendingCount, 1)
        restarted.weeklyFavorites.retry()
        try await wait(for: restarted.weeklyFavorites)
        restarted.backfillWeeklyFavorites()
        try await wait(for: restarted.weeklyFavorites)
        XCTAssertEqual(restarted.weeklyFavorites.pendingCount, 0)
        XCTAssertEqual(try note(in: new).components(separatedBy: "带本书来。").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    private func workspace() throws -> (URL, UserDefaults, ArticleStore) {
        let suite = "WeeklyFavoriteTests." + UUID().uuidString
        let root = try makeFolder(suite, in: .temporaryDirectory).resolvingSymlinksInPath()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return (root, defaults, ArticleStore(root: root.appending(path: "AppData")))
    }

    private func makeFolder(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func draft(_ text: String, _ translation: String) -> LearningFavorite.Draft {
        let excerpt = TextExcerpt(text: text, range: NSRange(location: 0, length: text.utf16.count), context: text)
        return .init(kind: .sentence, excerpt: excerpt, result: .init(translation: translation))
    }

    @MainActor
    private func wait(for sync: WeeklyFavoriteSync) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while sync.isWorking && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(sync.isWorking)
    }

    private func note(in folder: URL) throws -> String {
        let notes = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(notes.count, 1)
        return try String(contentsOf: XCTUnwrap(notes.first), encoding: .utf8)
    }
}
