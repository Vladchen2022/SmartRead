import XCTest
@testable import SmartRead

final class ArticleHistoryTests: XCTestCase {
    @MainActor
    func testLegacyArticleCanBeReopenedAndClearingHistoryKeepsTheCurrentArticle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = try Article(title: "First", body: "The old article is still readable.")
        try JSONEncoder().encode(first).write(to: root.appending(path: "CurrentArticle.json"))
        let store = ArticleStore(root: root)
        let reader = ReaderModel(store: store)
        XCTAssertEqual(reader.article, first)
        XCTAssertTrue(reader.history.isEmpty)

        try reader.importText("Here is some new text.", title: "Second")
        try reader.importText("A third article goes here.", title: "Third")
        let savedReader = ReaderModel(store: store)
        XCTAssertEqual(savedReader.article.title, "Third")
        XCTAssertEqual(savedReader.history.map(\.article.title), ["Second", "First"])

        let firstEntry = try XCTUnwrap(savedReader.history.last)
        try savedReader.openHistoryArticle(firstEntry.id)
        XCTAssertEqual(savedReader.article, first)
        XCTAssertEqual(savedReader.history.map(\.article.title), ["Third", "Second"])

        try savedReader.deleteHistoryArticle(try XCTUnwrap(savedReader.history.first).id)
        XCTAssertEqual(try store.load().history.map(\.article.title), ["Second"])
        let articleVersion = savedReader.articleVersion
        try savedReader.clearHistory()
        XCTAssertEqual(savedReader.articleVersion, articleVersion)
        let afterClear = ReaderModel(store: store)
        XCTAssertEqual(afterClear.article, first)
        XCTAssertTrue(afterClear.history.isEmpty)
    }

    @MainActor
    func testCorruptFilesStayIntactUntilEachIsRecovered() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        let course = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(store: store, learningStore: course)
        try reader.importText("A complete sentence.", title: "First")
        try reader.importText("Another complete sentence.", title: "Second")
        let position = SavedReadingPosition(sentenceStart: 3, completed: false)
        try store.savePositions(["key": position])
        try store.savePositions(["key": position])
        let damaged = Data("invalid".utf8)
        for kind in ArticleStore.RecordFile.allCases { try damaged.write(to: store.url(for: kind)) }
        let reopened = ReaderModel(store: store, learningStore: course)
        XCTAssertEqual(reopened.recoveryNeeded, [.library, .positions])
        XCTAssertThrowsError(try reopened.importText("New article.", title: "Third"))
        XCTAssertThrowsError(try store.savePositions([:]))
        try reopened.recover(.library)
        XCTAssertEqual(reopened.article.title, "First")
        XCTAssertEqual(reopened.recoveryNeeded, [.positions])
        XCTAssertEqual(try Data(contentsOf: store.url(for: .positions)), damaged)
        try reopened.recover(.positions)
        XCTAssertEqual(try store.loadPositions()["key"], position)
        XCTAssertTrue(reopened.recoveryNeeded.isEmpty)
        let copies = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".damaged-") }
        XCTAssertEqual(copies.count, 2)
        for url in copies { XCTAssertEqual(try Data(contentsOf: url), damaged) }
        try reopened.importText("New article.", title: "Third")
        XCTAssertEqual(try store.load().current?.title, "Third")
    }

    func testRecoveryPreservesBothDamagedCopiesWhenThereIsNoUsableBackup() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        try store.savePositions([:])
        let url = store.url(for: .positions)
        try Data("bad primary".utf8).write(to: url)
        try Data("bad backup".utf8).write(to: url.appendingPathExtension("backup"))
        try store.recover(.positions)
        XCTAssertTrue(try store.loadPositions().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let copies = try files.filter { $0.lastPathComponent.contains("damaged-") }.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(Set(copies), ["bad primary", "bad backup"])
    }

    @MainActor
    func testRepeatedImportsDoNotDuplicateAnArticleOrArchiveTheExample() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = ReaderModel(store: ArticleStore(root: root))
        XCTAssertEqual(reader.article, .sample)
        try reader.importText("Keep the book.", title: "A")
        XCTAssertTrue(reader.history.isEmpty)
        try reader.importText("Keep the book.", title: "A")
        XCTAssertTrue(reader.history.isEmpty)
        try reader.importText("Return the pen.", title: "B")
        try reader.importText("Keep the book.", title: "A")
        XCTAssertEqual(reader.history.map(\.article.title), ["B"])
    }

    @MainActor
    func testResumeSurvivesRestartAndSkipsCompletedArticles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root.appending(path: "Library"))
        let learning = LearningRecordStore(projectRoot: root)
        let reader = ReaderModel(store: store, learningStore: learning)
        let sentence = "The learner opened a new book."
        let first = "The room was quiet.\n\n\(sentence) Then class began."
        let position = (first as NSString).range(of: "opened").location
        try reader.importText(first, title: "First")
        reader.didScroll(to: position)
        reader.didScroll(to: 0, saveForResume: false)
        XCTAssertNil(reader.learningRecord)
        try reader.importText("Today we will read another short article.", title: "Second")
        XCTAssertEqual(reader.previousReadingEntry?.article.title, "First")

        let restarted = ReaderModel(store: store, learningStore: learning)
        try restarted.openHistoryArticle(try XCTUnwrap(restarted.previousReadingEntry?.id))
        let target = (first as NSString).range(of: sentence)
        XCTAssertEqual(restarted.jump?.range, target)
        XCTAssertEqual(restarted.jump?.alignToTop, true)
        XCTAssertEqual(ReaderModel(store: store, learningStore: learning).jump?.range, target)
        try restarted.completeReading(difficulty: .justRight, feedback: "")
        try restarted.importText("Today we will read another short article.", title: "Second")
        XCTAssertNil(restarted.previousReadingEntry)
    }
}
