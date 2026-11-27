import XCTest
@testable import SmartRead

final class ListeningMarksTests: XCTestCase {
    @MainActor
    func testMarksPersistInSourceOrderWithoutDuplicatesAndStayWithTheirMaterial() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "ListeningMarks.json")
        let marks = ListeningMarks(file: file)
        let text = AssistantQuestionSource(title: "Reading", location: .text(
            material: "article-a", range: NSRange(location: 0, length: 9), pdf: nil
        ))
        let second = AssistantQuestionSource(title: "Reading", location: .text(
            material: "article-a", range: NSRange(location: 10, length: 9), pdf: nil
        ))
        let audioID = UUID()
        let audio = AssistantQuestionSource(title: "Lesson", location: .audio(
            entry: audioID, cue: UUID(), range: NSRange(location: 0, length: 9)
        ))
        let url = URL(fileURLWithPath: "/fixture.mkv")
        let video = AssistantQuestionSource(title: "Video", location: .video(
            file: url, cues: [.init(start: 10_000, text: "Look back.")]
        ), videoTrack: .embedded(1))
        marks.add(.init(passage: "Go ahead.", source: second))
        marks.add(.init(passage: "Come back", source: text))
        marks.add(.init(passage: "Come back", source: text))
        marks.add(.init(passage: "Come back", source: audio), milliseconds: 700)
        marks.add(.init(passage: "Look back.", source: video), milliseconds: 10_100)
        XCTAssertNil(marks.issue)

        let reloaded = ListeningMarks(file: file)
        XCTAssertEqual(reloaded.marks(for: .text, materialID: "article-a").map(\.passage), ["Come back", "Go ahead."])
        XCTAssertTrue(reloaded.marks(for: .text, materialID: "article-b").isEmpty)
        XCTAssertEqual(reloaded.marks(for: .audio, materialID: audioID.uuidString).first?.milliseconds, 700)
        let videoMark = try XCTUnwrap(reloaded.marks(for: .video, materialID: url.absoluteString).first)
        let cue = SubtitleCue(startMilliseconds: 10_000, endMilliseconds: 11_000, text: "Look back.")
        XCTAssertTrue(videoMark.matches(cue, track: .embedded(1)))
        XCTAssertFalse(videoMark.matches(cue, track: .embedded(2)))
        reloaded.remove(videoMark.id)
        XCTAssertTrue(ListeningMarks(file: file).marks(for: .video, materialID: url.absoluteString).isEmpty)
    }

    @MainActor
    func testInvalidMarksFileIsPreservedAndReported() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let corrupt = Data("unreadable".utf8)
        try corrupt.write(to: file)
        let marks = ListeningMarks(file: file)
        let source = AssistantQuestionSource(title: "Reading", location: .text(
            material: "text", range: NSRange(location: 0, length: 5), pdf: nil
        ))
        marks.add(.init(passage: "Hello", source: source))
        XCTAssertNotNil(marks.issue)
        XCTAssertTrue(marks.marks(for: .text, materialID: "text").isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor
    func testReplaySuggestionsAndMediaFavoritesAreIndependentOfManualMarks() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let marks = ListeningMarks(file: file)
        let entry = UUID()
        let source = AssistantQuestionSource(title: "Audio", location: .audio(
            entry: entry, cue: UUID(), range: NSRange(location: 0, length: 12)
        ))
        let target = ListeningTarget(reference: .init(passage: "Keep trying.", source: source), milliseconds: 2_000)

        marks.recordReplay(target, speed: .normal)
        var row = try XCTUnwrap(marks.rows(for: .audio, materialID: entry.uuidString).first)
        XCTAssertFalse(row.isSuggested)
        marks.recordReplay(target, speed: .threeQuarters)
        row = try XCTUnwrap(marks.rows(for: .audio, materialID: entry.uuidString).first)
        XCTAssertEqual(row.replays, 2)
        XCTAssertEqual(row.slowReplays, 1)
        XCTAssertTrue(row.isSuggested)
        XCTAssertFalse(row.isMarked)

        XCTAssertTrue(marks.add(target.reference, milliseconds: target.milliseconds))
        XCTAssertTrue(marks.add(target.reference, milliseconds: target.milliseconds))
        XCTAssertEqual(marks.marks(for: .audio, materialID: entry.uuidString).map(\.id), [row.id])
        try marks.toggleMediaFavorite(row.id)
        marks.remove(row.id)
        let reopened = ListeningMarks(file: file)
        row = try XCTUnwrap(reopened.rows(for: .audio, materialID: entry.uuidString).first)
        XCTAssertEqual(row.isSaved, true)
        XCTAssertFalse(row.isMarked)
        XCTAssertFalse(row.isSuggested)
        XCTAssertEqual(row.replays, 2)
        reopened.recordReplay(target, speed: .threeQuarters)
        reopened.recordReplay(target, speed: .threeQuarters)
        row = try XCTUnwrap(reopened.rows(for: .audio, materialID: entry.uuidString).first)
        XCTAssertTrue(row.isSuggested)
        XCTAssertEqual(row.slowReplays, 3)
    }

    @MainActor
    func testTextMarkCanBeResolvedFromTheClickOrSelectionAndRemovedFromReview() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = ReaderModel(store: ArticleStore(root: root), learningStore: LearningRecordStore(projectRoot: root))
        let body = "The rain stopped. The rain stopped."
        try reader.importText(body, title: "Rain")
        let sentences = reader.articleForListening(fromHere: false).sentences
        let first = try XCTUnwrap(reader.questionReference(for: sentences[0]))
        let second = try XCTUnwrap(reader.questionReference(for: sentences[1]))
        XCTAssertTrue(reader.listeningMarks.add(first))
        XCTAssertTrue(reader.listeningMarks.add(second))
        reader.listeningMarks.recordReplay(.init(reference: second), speed: .normal)
        reader.listeningMarks.recordReplay(.init(reference: second), speed: .threeQuarters)
        let visible = reader.textListeningMarks
        XCTAssertEqual(visible.map(\.range), sentences.map(\.range))
        let word = NSRange(location: sentences[1].range.location + 4, length: 4)
        let selection = try XCTUnwrap(TextListeningMark.matching(visible, selection: word, click: nil))
        XCTAssertEqual(TextListeningMark.matching(visible, selection: nil, click: word.location), selection)
        XCTAssertNil(TextListeningMark.matching(visible, selection: NSRange(location: 0, length: body.utf16.count), click: nil))
        reader.listeningMarks.remove(selection.id)
        XCTAssertEqual(reader.textListeningMarks.map(\.range), [sentences[0].range])
        let removed = try XCTUnwrap(reader.listeningMarks.rows(for: .text, materialID: reader.questionMaterialID)
            .first { $0.id == selection.id })
        XCTAssertFalse(removed.isMarked || removed.isSuggested)
        XCTAssertEqual(removed.replays, 2)
    }

    @MainActor
    func testSavingMediaFromTheSidebarDoesNotCreateAListeningMark() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "ListeningMarks.json")
        let marks = ListeningMarks(file: file)
        let entry = UUID()
        let source = AssistantQuestionSource(title: "Audio", location: .audio(
            entry: entry, cue: UUID(), range: NSRange(location: 0, length: 12)
        ))
        let target = ListeningTarget(reference: .init(passage: "Keep trying.", source: source), milliseconds: 2_000)
        try marks.toggleMediaFavorite(target)
        XCTAssertTrue(marks.isMediaFavorite(target))
        XCTAssertTrue(marks.marks(for: .audio, materialID: entry.uuidString).isEmpty)
        let reopened = ListeningMarks(file: file)
        XCTAssertTrue(reopened.isMediaFavorite(target))
        XCTAssertTrue(reopened.add(target.reference, milliseconds: target.milliseconds))
        try reopened.toggleMediaFavorite(target)
        XCTAssertFalse(reopened.isMediaFavorite(target))
        XCTAssertEqual(reopened.marks(for: .audio, materialID: entry.uuidString).count, 1)
    }

    @MainActor
    func testOriginalSentenceFavoriteJoinsArticleFavoritesAndSurvivesRemovingTheMark() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root.appending(path: "Library"))
        let reader = ReaderModel(store: store, learningStore: LearningRecordStore(projectRoot: root))
        try reader.importText("The rain stopped. The road was still wet.", title: "Rain")
        let sentence = try XCTUnwrap(reader.articleForListening(fromHere: false).sentences.first)
        let reference = try XCTUnwrap(reader.questionReference(for: sentence))
        reader.listeningMarks.add(reference)
        let mark = try XCTUnwrap(reader.listeningMarks.marks(for: .text, materialID: reader.questionMaterialID).first)
        try await reader.toggleOriginalFavorite(for: mark)
        XCTAssertEqual(reader.favorites.first?.favorite.kind, .originalSentence)
        XCTAssertEqual(reader.favorites.first?.favorite.selectedText, "The rain stopped.")
        reader.listeningMarks.remove(mark.id)
        let reopened = ReaderModel(store: store, learningStore: LearningRecordStore(projectRoot: root))
        XCTAssertNotNil(reopened.originalFavoriteID(for: mark))
        XCTAssertTrue(reopened.listeningMarks.marks(for: .text, materialID: reopened.questionMaterialID).isEmpty)
        try await reopened.toggleOriginalFavorite(for: mark)
        XCTAssertTrue(reopened.favorites.isEmpty)
    }
}
