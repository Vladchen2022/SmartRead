import Foundation
import XCTest
@testable import SmartRead

final class ObsidianExportServiceTests: XCTestCase {
    private var directory: URL!
    private var vault: URL!
    private var repository: LearningRepository!
    private let service = ObsidianExportService()
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let date = ISO8601DateFormatter().date(from: "2026-10-25T08:00:00Z")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        vault = directory.appending(path: "Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        repository = try LearningRepository(inMemory: true)
    }
    override func tearDownWithError() throws {
        repository = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoActivityCreatesNoDirectoryOrDailyNote() throws {
        let result = try service.synchronize(activities: [], to: vault)
        XCTAssertEqual(result.activityCount, 0)
        XCTAssertTrue(result.noteURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWordAndSentenceShareOneDailyNoteWithContextAndProvenance() throws {
        let word = try recordWord()
        let sentence = try recordSentence()
        let result = try service.synchronize(activities: [word, sentence], to: vault)
        XCTAssertEqual(result.noteURLs, [note])
        let text = try String(contentsOf: note, encoding: .utf8)
        for value in ["# AEVP-20261025", "单词查询 · up", "整句解析", "原英文字幕", "前一句英文上下文",
                      "后一句英文上下文", "目标词位置（UTF-16", "00:12.350", "Asia/Shanghai",
                      "英文例句（模型输出，仅本地格式检查）", "本次解析采用的英文", "相近表达 1", "Don't give up."] {
            XCTAssertTrue(text.contains(value), value)
        }
        XCTAssertTrue(text.contains("local-test"))
        XCTAssertTrue(text.contains("未进行额外大模型语义复核"))
        XCTAssertFalse(text.contains("已进行语义与双语对应复核"))
        XCTAssertTrue(text.contains("\n\n- 最近成功时间："))
        XCTAssertTrue(text.contains("\n\n<!-- AEVP:DAILY:END:"))
        XCTAssertEqual(text.components(separatedBy: "<!-- AEVP:DAILY:BEGIN:").count - 1, 2)
        XCTAssertEqual(try markdownFiles().count, 1)
    }

    func testRepeatedUseAndRestartUpdateSameBlockAndPreserveManualText() throws {
        _ = try recordWord()
        _ = try service.synchronize(activities: repository.fetchActivities(), to: vault)
        var text = try String(contentsOf: note, encoding: .utf8)
        text += "\n## 手写补充\nKeep this exactly.\n"
        try text.write(to: note, atomically: true, encoding: .utf8)
        _ = try recordWord()
        _ = try ObsidianExportService().synchronize(activities: repository.fetchActivities(), to: vault)
        let final = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(final.contains("Keep this exactly."))
        XCTAssertTrue(final.contains("当日同语境操作次数：2"))
        XCTAssertEqual(final.components(separatedBy: "<!-- AEVP:DAILY:BEGIN:").count - 1, 1)
        XCTAssertEqual(try markdownFiles().count, 1)
        let modified = try note.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try service.synchronize(activities: repository.fetchActivities(), to: vault)
        XCTAssertEqual(try note.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
    }

    func testOnlyDaysWithInteractionProduceNotes() throws {
        let today = try recordWord()
        let next = try recordWord(at: date.addingTimeInterval(86_400))
        _ = try service.synchronize(activities: [today, next], to: vault)
        XCTAssertEqual(Set(try markdownFiles().map(\.lastPathComponent)), ["AEVP-20261025.md", "AEVP-20261026.md"])
    }

    func testExistingSpaceNamedEnglishFolderIsReusedWithoutParallelDirectory() throws {
        let english = vault.appending(path: "03 英语学习")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        let entry = try recordWord()
        let root = try service.synchronize(activities: [entry], to: vault)
        let direct = try service.synchronize(activities: [entry], to: english)
        XCTAssertEqual(root.noteURLs, direct.noteURLs)
        XCTAssertTrue(root.noteURLs[0].path.contains("/03 英语学习/AEVP/AEVP-20261025.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appending(path: "03_英语学习").path))
    }

    func testAmbiguousFolderAndMissingVaultDoNotWrite() throws {
        for name in ["03_英语学习", "03 英语学习"] {
            try FileManager.default.createDirectory(at: vault.appending(path: name), withIntermediateDirectories: true)
        }
        let entry = try recordWord()
        XCTAssertThrowsError(try service.synchronize(activities: [entry], to: vault))
        XCTAssertThrowsError(try service.synchronize(activities: [entry], to: vault.appending(path: "missing")))
    }

    func testFailedOrPendingQueryNeverExportsUnverifiedResult() throws {
        let pending = try repository.recordInteraction(draft(.word), at: date, timeZone: zone)
        _ = try service.synchronize(activities: [pending], to: vault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        _ = try repository.finishInteraction(pending.handle, status: .failed, error: "双语例句未通过检查")
        _ = try service.synchronize(activities: repository.fetchActivities(), to: vault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
    }

    func testFailedRepeatKeepsPriorSuccessfulMaterialWithExplicitLabel() throws {
        _ = try recordWord()
        _ = try service.synchronize(activities: repository.fetchActivities(), to: vault)
        let original = try String(contentsOf: note, encoding: .utf8)
        let failed = try repository.recordInteraction(draft(.word), at: date, timeZone: zone)
        _ = try repository.finishInteraction(failed.handle, status: .failed, error: "offline")
        _ = try service.synchronize(activities: repository.fetchActivities(), to: vault)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(text, original)
        XCTAssertTrue(text.contains("Don't give up."))
        XCTAssertFalse(text.contains("查询失败"))
        // A later successful answer is still unconfirmed. It must not inherit
        // the earlier answer's permission to overwrite the existing note.
        let newer = try repository.recordInteraction(draft(.word), at: date, timeZone: zone)
        let word = try XCTUnwrap(repository.fetchActivities().first?.wordExplanation)
        _ = try repository.finishInteraction(newer.handle, status: .completed, word: word)
        _ = try service.synchronize(activities: repository.fetchActivities(), to: vault)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), original)
        XCTAssertTrue(try repository.fetchConfirmedActivities(dayKey: "20261025").isEmpty)
    }

    func testDamagedManagedBlockAndSymlinkAreNotOverwritten() throws {
        let entry = try recordWord()
        _ = try service.synchronize(activities: [entry], to: vault)
        var text = try String(contentsOf: note, encoding: .utf8)
        text = text.replacingOccurrences(of: "<!-- AEVP:DAILY:END:\(entry.id.uuidString) -->", with: "")
        try text.write(to: note, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.synchronize(activities: [entry], to: vault))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), text)
        let external = directory.appending(path: "outside.md")
        try "DO NOT CHANGE".write(to: external, atomically: true, encoding: .utf8)
        let tomorrow = try recordWord(at: date.addingTimeInterval(86_400))
        try FileManager.default.createSymbolicLink(at: destination.appending(path: "AEVP-20261026.md"), withDestinationURL: external)
        XCTAssertThrowsError(try service.synchronize(activities: [tomorrow], to: vault))
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "DO NOT CHANGE")
    }

    private var destination: URL { vault.appending(path: "03_英语学习/AEVP") }
    private var note: URL { destination.appending(path: "AEVP-20261025.md") }
    private func markdownFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
    }
    private func draft(_ kind: LearningActivityKind) -> LearningActivityDraft {
        LearningActivityDraft(kind: kind, videoURL: directory.appending(path: "Episode 01.mkv"),
            english: "I gave up.", chinese: "我放弃了。", previousEnglish: "It was hard.", nextEnglish: "Try again.",
            startMilliseconds: 12_350, endMilliseconds: 14_900,
            word: kind == .word ? SubtitleWord(text: "up", range: NSRange(location: 7, length: 2)) : nil)
    }
    private func recordWord(at timestamp: Date? = nil) throws -> LearningActivity {
        let entry = try repository.recordInteraction(draft(.word), at: timestamp ?? date, timeZone: zone)
        let explanation = WordExplanation(lemma: "up", partOfSpeechZh: "小品词", meaningZh: "搭配 give up 表示放弃",
            usageNoteZh: "不要按向上理解。", exampleEnglish: "Don't give up.", exampleChinese: "不要放弃。")
        _ = try repository.finishInteraction(entry.handle, status: .completed, word: explanation, modelID: "local-test")
        XCTAssertTrue(try repository.confirmInteraction(entry.handle, at: timestamp ?? date))
        return try XCTUnwrap(repository.fetchActivities(dayKey: entry.dayKey).first { $0.id == entry.id })
    }
    private func recordSentence() throws -> LearningActivity {
        let entry = try repository.recordInteraction(draft(.sentence), at: date, timeZone: zone)
        let analysis = SentenceAnalysis(translationZh: "我放弃了。", keyExpression: "give up", expressionMeaningZh: "放弃",
            usageNoteZh: "过去式是 gave up。", exampleEnglish: "Don't give up.", exampleChinese: "不要放弃。",
            similarExpressions: [SimilarExpression(english: "I stopped trying.", chinese: "我不再尝试了。"),
                                 SimilarExpression(english: "I decided to quit.", chinese: "我决定放弃。")],
            analyzedEnglish: "I gave up.")
        _ = try repository.finishInteraction(entry.handle, status: .completed, sentence: analysis, modelID: "local-test")
        XCTAssertTrue(try repository.confirmInteraction(entry.handle, at: date))
        return try XCTUnwrap(repository.fetchActivities(dayKey: entry.dayKey).first { $0.id == entry.id })
    }
}
