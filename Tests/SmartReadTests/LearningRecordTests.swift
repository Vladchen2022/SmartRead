import XCTest
@testable import SmartRead

final class LearningRecordTests: XCTestCase {
    @MainActor
    func testBackgroundLoadingKeepsRecordsWithTheirArticle() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root.appending(path: "Library"))
        let records = LearningRecordStore(projectRoot: root)
        let first = try XCTUnwrap(LearningArticleInput.parse(markdown(body: "First reading material."), relativePath: nil))
        let second = try XCTUnwrap(LearningArticleInput.parse(markdown(body: "A separate text."), relativePath: nil))
        let firstRecord = LearningRecord(article: first, now: .now)
        let secondRecord = LearningRecord(article: second, now: .now)
        try records.save(firstRecord)
        try records.save(secondRecord)
        try store.save(ArticleLibrary(current: first))

        let reader = ReaderModel(store: store, learningStore: records, loadsLearningRecordsInBackground: true)
        XCTAssertTrue(reader.isLoadingLearningRecord)
        XCTAssertEqual(reader.article, first)
        let file = root.appending(path: "Article.md")
        try markdown(body: second.body).write(to: file, atomically: true, encoding: .utf8)
        let secondSource = try XCTUnwrap(LearningArticleInput.parse(markdown(body: second.body), relativePath: "Article.md"))
        try reader.importFile(file)
        let deadline = ContinuousClock.now + .seconds(3)
        while reader.isLoadingLearningRecord && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(reader.isLoadingLearningRecord)
        XCTAssertEqual(reader.article, secondSource)
        XCTAssertEqual(reader.learningRecord?.articleId, secondRecord.articleId)
    }

    func testDamagedCourseRecordsDoNotBlockOtherCoursesOrDuplicateTheDamagedOne() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LearningRecordStore(projectRoot: root)
        let first = try XCTUnwrap(LearningArticleInput.parse(markdown(body: "First story."), relativePath: nil))
        let second = try XCTUnwrap(LearningArticleInput.parse(markdown(body: "Second story."), relativePath: nil))
        let record = LearningRecord(article: first, now: .now)
        try store.save(record)
        let broken = store.file(for: record.articleId)
        let bytes = Data("broken".utf8)
        try bytes.write(to: broken)
        XCTAssertThrowsError(try store.load(for: first))
        XCTAssertThrowsError(try store.save(record))
        XCTAssertEqual(try store.scan(for: second).unreadable, [broken.lastPathComponent])
        let other = LearningRecord(article: second, now: .now)
        try store.save(other)
        XCTAssertEqual(try store.load(for: second)?.articleId, other.articleId)
        XCTAssertEqual(try Data(contentsOf: broken), bytes)
        try FileManager.default.removeItem(at: broken)
        XCTAssertThrowsError(try store.load(for: first))
    }

    func testMarkedMarkdownAndOrdinaryMarkdownAreDistinguished() throws {
        let text = markdown(body: "One paragraph.\n\nThen another.")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let article = try XCTUnwrap(LearningArticleInput.parse("\u{FEFF}" + text, relativePath: "Lesson.md"))
        XCTAssertEqual(article.title, "By the River")
        XCTAssertEqual(article.body, "One paragraph.\n\nThen another.")
        XCTAssertEqual(article.learningSource?.readingDate, "2026-11-23")
        XCTAssertEqual(article.learningSource?.course, "英语精读")
        XCTAssertEqual(article.learningSource?.lesson, "第 1 课")
        XCTAssertEqual(article.learningSource?.titleZh, "在河边")
        XCTAssertNil(try LearningArticleInput.parse("---\ntitle: Other\n---\nHello.", relativePath: nil))
        XCTAssertThrowsError(try LearningArticleInput.parse(text.replacingOccurrences(of: "smartreadFormat: 1",
                                                                                       with: "smartreadFormat: 2"),
                                                             relativePath: nil))
        XCTAssertThrowsError(try LearningArticleInput.parse(text.replacingOccurrences(of: "2026-11-23\"", with: "2026-02-30\""),
                                                             relativePath: nil))
    }

    @MainActor
    func testCompleteLearningWorkflowPersistsAcrossImportsAndRestart() throws {
        let samplePath = ProcessInfo.processInfo.environment["SMARTREAD_TEST_SAMPLE_DIRECTORY"]
        let root = samplePath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? temporaryRoot()
        defer { if samplePath == nil { try? FileManager.default.removeItem(at: root) } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "By the River.md")
        let sentence = "She sat on the river bank."
        let body = "A boat called 🛶 passed by. \(sentence)\n\nLater, he went to the bank to deposit cash."
        try markdown(body: body).write(to: file, atomically: true, encoding: .utf8)
        let store = ArticleStore(root: root.appending(path: "Library"))
        let learningStore = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(store: store, learningStore: learningStore)

        try reader.importFile(file)
        XCTAssertEqual(reader.article.body, body)
        XCTAssertNil(reader.learningRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: learningStore.directory.path))

        let riverBank = draft(.word, "bank", in: body, result: .init(definition: "河岸"))
        let moneyBank = draft(.word, "bank", in: body, options: .backwards, result: .init(definition: "银行"))
        let phrase = draft(.phrase, "sat on", in: body, result: .init(definition: "坐在……上"))
        let translation = draft(.sentence, sentence, in: body, result: .init(translation: "她坐在河岸上。"))
        let grammar = draft(.grammar, sentence, in: body, result: .init(analysis: "She 是主语，sat 是谓语。"))
        let crossing = draft(.sentence, "passed by. She sat", in: body, result: .init(translation: "驶过。她坐着。"))
        for favorite in [riverBank, moneyBank, phrase, translation, grammar, crossing] {
            try reader.saveFavorite(favorite)
        }
        let first = try XCTUnwrap(reader.learningRecord)
        XCTAssertEqual(first.reading.status, .inProgress)
        XCTAssertNil(first.reading.completedAt)
        XCTAssertEqual(first.favorites.count, 6)
        XCTAssertEqual(first.favorites[0].range.location, (body as NSString).range(of: "bank").location)
        XCTAssertEqual(first.favorites[0].sentence, sentence)
        XCTAssertEqual(first.favorites[1].paragraph, 2)
        XCTAssertNotEqual(first.favorites[0].id, first.favorites[1].id)
        XCTAssertEqual(first.favorites[5].sentence, "A boat called 🛶 passed by. \(sentence)")
        try reader.saveFavorite(riverBank)
        XCTAssertEqual(reader.learningRecord?.favorites.count, 6)
        XCTAssertEqual(reader.learningRecord?.updatedAt, first.updatedAt)

        try reader.toggleFavorite(riverBank)
        XCTAssertFalse(reader.isFavorite(riverBank))
        XCTAssertTrue(reader.isFavorite(moneyBank))
        try reader.toggleFavorite(riverBank)
        XCTAssertTrue(reader.learningRecord?.favorites.contains(where: { $0.id == first.favorites[0].id }) == true)
        try reader.removeFavorite(first.favorites[5].id)

        try reader.importFile(file)
        XCTAssertTrue(reader.history.isEmpty)
        XCTAssertEqual(reader.learningRecord?.articleId, first.articleId)
        XCTAssertEqual(reader.learningRecord?.reading.status, .inProgress)
        try reader.completeReading(difficulty: .justRight, feedback: "  river bank 更好记了。  ", reason: .phrases)
        let complete = try XCTUnwrap(reader.learningRecord)
        XCTAssertGreaterThan(complete.updatedAt, first.updatedAt)

        let contents = try Data(contentsOf: learningStore.file(for: first.articleId))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: contents) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["articleId"] as? String, first.articleId.uuidString.lowercased())
        XCTAssertEqual(json["sourcePath"] as? String, "By the River.md")
        XCTAssertEqual(json["body"] as? String, body)
        XCTAssertEqual(json["offsetUnit"] as? String, "utf16")
        XCTAssertEqual(json["bodySha256"] as? String, LearningRecord.fingerprint(body))
        XCTAssertEqual((json["reading"] as? [String: Any])?["difficultyReason"] as? String, "phrases")

        try reader.importText("This next article has no learning record.", title: "Next")
        XCTAssertNil(reader.learningRecord)
        let restarted = ReaderModel(store: store, learningStore: learningStore)
        let previous = try XCTUnwrap(restarted.history.first)
        try restarted.openHistoryArticle(previous.id)
        XCTAssertTrue(restarted.isFavorite(riverBank))
        XCTAssertEqual(restarted.learningRecord?.reading.status, .completed)
        XCTAssertEqual(restarted.learningRecord?.reading.difficulty, .justRight)
        XCTAssertEqual(restarted.learningRecord?.reading.difficultyReason, .phrases)
        XCTAssertEqual(restarted.learningRecord?.reading.feedback, "river bank 更好记了。")
        let saved = try XCTUnwrap(restarted.learningRecord?.favorites.first(where: { $0.id == first.favorites[0].id }))
        try restarted.showFavorite(saved.id)
        XCTAssertEqual(restarted.shownFavorite?.result.definition, "河岸")
        XCTAssertEqual(restarted.jump?.select, true)
        XCTAssertEqual(restarted.jump?.range, riverBank.excerpt.range)
        XCTAssertNil(restarted.lookup)
        try restarted.importText("This next article has no learning record.", title: "Next")
        try restarted.clearHistory()
        XCTAssertTrue(restarted.history.isEmpty)
        XCTAssertEqual(try Data(contentsOf: learningStore.file(for: first.articleId)), contents)
        try restarted.importFile(file)
        XCTAssertEqual(ReaderModel(store: store, learningStore: learningStore).learningRecord?.articleId, first.articleId)
    }

    @MainActor
    func testLegacyRecordAcquiresSourceWithoutReplacingOtherVersions() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let learningStore = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(store: ArticleStore(root: root.appending(path: "Library")), learningStore: learningStore)
        let body = "She sat on the river bank."
        try reader.importText(body, title: "Old title")
        try reader.saveFavorite(draft(.word, "bank", in: body, result: .init(definition: "河岸")))
        let legacy = try XCTUnwrap(reader.learningRecord)
        try learningStore.save(legacy)
        let file = root.appending(path: "Article.md")
        try markdown(body: body).write(to: file, atomically: true, encoding: .utf8)
        try reader.importFile(file)
        XCTAssertEqual(reader.learningRecord?.articleId, legacy.articleId)
        XCTAssertEqual(reader.learningRecord?.sourceId, "english-reading:2026-11-23:01")
        XCTAssertEqual(reader.learningRecord?.favorites.map(\.id), legacy.favorites.map(\.id))

        try markdown(body: "She watched the river.").write(to: file, atomically: true, encoding: .utf8)
        try reader.importFile(file)
        XCTAssertNil(reader.learningRecord)
        try reader.completeReading(difficulty: .tooEasy, feedback: "")
        XCTAssertNotEqual(reader.learningRecord?.articleId, legacy.articleId)
        XCTAssertEqual(try Data(contentsOf: learningStore.file(for: legacy.articleId)).isEmpty, false)

        try markdown(body: body).replacingOccurrences(of: ":01\"", with: ":02\"")
            .write(to: file, atomically: true, encoding: .utf8)
        try reader.importFile(file)
        XCTAssertNil(reader.learningRecord)
        try reader.completeReading(difficulty: .tooHard, feedback: "")
        XCTAssertNotEqual(reader.learningRecord?.articleId, legacy.articleId)
        XCTAssertEqual(try learningStore.load(for: try Article.pasted(body, title: "Ambiguous"))?.articleId, nil)
    }

    @MainActor
    func testFailedExportLeavesReadingStateUnchanged() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let learningStore = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(store: ArticleStore(root: root.appending(path: "Library")), learningStore: learningStore)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Article.md")
        try markdown(body: "She sat by the river.").write(to: file, atomically: true, encoding: .utf8)
        try reader.importFile(file)
        try Data().write(to: learningStore.directory)
        XCTAssertThrowsError(try reader.completeReading(difficulty: .justRight, feedback: ""))
        XCTAssertNil(reader.learningRecord)
    }

    @MainActor
    func testImportedArticleCanSaveAndReopenWhileCourseDirectoryIsUnavailable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ArticleStore(root: root.appending(path: "Library"))
        let courseRecords = LearningRecordStore(projectRoot: root)
        try Data().write(to: courseRecords.directory)
        let reader = ReaderModel(store: store, learningStore: courseRecords, loadsLearningRecordsInBackground: true)
        let body = "Today I read a short story. Then I told a friend about it."
        let file = root.appending(path: "My Article.txt")
        try body.write(to: file, atomically: true, encoding: .utf8)
        try reader.importFile(file)
        XCTAssertFalse(reader.isLoadingLearningRecord)
        let favorite = draft(.sentence, "Today I read a short story.", in: body, result: .init(translation: "今天我读了一个短故事。"))
        try reader.toggleFavorite(favorite)
        let reopened = ReaderModel(store: store, learningStore: courseRecords, loadsLearningRecordsInBackground: true)
        XCTAssertEqual(reopened.favoriteCount, 1)
        let entry = try XCTUnwrap(reopened.favorites.first)
        try reopened.showFavorite(entry.id)
        XCTAssertEqual(reopened.shownFavorite?.result.translation, "今天我读了一个短故事。")
        XCTAssertEqual(reopened.jump?.range, favorite.excerpt.range)
    }

    @MainActor
    func testLegacyImportMergesWithNewFavoritesAndDoesNotRestoreRemovedItems() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        let course = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(store: store, learningStore: course)
        let body = "The first sentence is here. This second sentence is new."
        try reader.importText(body, title: "Imported")
        let old = draft(.sentence, "The first sentence is here.", in: body, result: .init(translation: "第一句。"))
        let new = draft(.sentence, "This second sentence is new.", in: body, result: .init(translation: "第二句。"))
        try reader.saveFavorite(old)
        let legacy = try XCTUnwrap(reader.learningRecord)
        try reader.removeFavorite(try XCTUnwrap(reader.favorites.first?.id))
        try course.save(legacy)

        let reopened = ReaderModel(store: store, learningStore: course)
        try reopened.saveFavorite(new)
        let deadline = ContinuousClock.now + .seconds(3)
        while reopened.learningRecord?.importedLegacy != true && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(Set(reopened.favorites.map(\.favorite.selectedText)), [old.excerpt.text, new.excerpt.text])
        let local = ImportedLearningRecords(root: store.importedLearningDirectory)
        let oldID = try XCTUnwrap(reopened.favorites.first { $0.favorite.selectedText == old.excerpt.text }?.id)
        try reopened.removeFavorite(oldID)
        XCTAssertEqual(try local.importLegacy(legacy, for: reopened.article)?.favorites.count, 1)
    }

    private func markdown(body: String) -> String {
        """
        ---
        smartreadFormat: 1
        sourceId: "english-reading:2026-11-23:01"
        title: "By the River"
        readingDate: "2026-11-23"
        course: "英语精读"
        lesson: "第 1 课"
        titleZh: "在河边"
        ---

        \(body)
        """
    }

    private func draft(_ kind: LearningFavorite.Kind, _ text: String, in body: String,
                       options: NSString.CompareOptions = [], result: LearningFavorite.Result) -> LearningFavorite.Draft {
        let range = (body as NSString).range(of: text, options: options)
        return .init(kind: kind, excerpt: TextExcerpt(text: text, range: range, context: ""), result: result)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }
}
