import Foundation
import SmartReadSync
import XCTest
@testable import SmartRead

final class TextDeviceSyncTests: XCTestCase {
    @MainActor
    func testMobileImportReachesDesktopHistoryAndOfflineMarksMergeBothWays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let desktopRoot = root.appendingPathComponent("Mac")
        let macStore = ArticleStore(root: desktopRoot)
        let mac = ReaderModel(defaults: defaults, store: macStore)
        try mac.importText("The original stays open. Another person reads the same book.", title: "Mac original")
        await mac.connectTextSync(to: folder)
        XCTAssertNil(mac.textSync.error)
        XCTAssertNil(mac.textSyncIssue)

        let phoneRoot = root.appendingPathComponent("iPhone")
        let phone = ReadingSyncStore(root: phoneRoot)
        try phone.connect(to: folder)
        await phone.sync()
        XCTAssertEqual(phone.materials.map(\.title), ["Mac original"])
        let text = try ReadingMaterial(title: "Imported on iPhone", body: "She waited on the steps. The book fell open. She read the last page.")
        let sentences = ReadingAnchor.sentences(in: text.body)
        XCTAssertEqual(sentences.count, 3)
        let first = try XCTUnwrap(sentences.first)
        let second = try XCTUnwrap(sentences.dropFirst().first)
        let last = try XCTUnwrap(sentences.last)
        let favorite = ReadingFavorite(kind: "sentence", anchor: second, sentence: second.quote, translation: "书摊开了。")
        try phone.record([
            .material(text), .progress(material: text.id, .init(offset: second.offset, completed: false)),
            .mark(material: text.id, second, true), .favorite(material: text.id, id: favorite.id, favorite)
        ])
        try phone.countSlow(material: text.id, anchor: second)
        XCTAssertTrue(phone.hasPendingChanges)
        await phone.sync()
        XCTAssertFalse(phone.hasPendingChanges)
        await mac.syncTextLibrary()
        XCTAssertNil(mac.textSync.error)
        XCTAssertNil(mac.textSyncIssue)
        XCTAssertEqual(mac.article.title, "Mac original")
        let entry = try XCTUnwrap(mac.history.first { $0.article.title == text.title })
        try mac.openHistoryArticle(entry.id)
        XCTAssertEqual(mac.jump?.range.location, second.offset)
        XCTAssertEqual(mac.listeningMarks.rows(for: .text, materialID: text.legacyKey).map(\.passage), [second.quote])

        let firstRange = NSRange(location: first.offset, length: first.length)
        let firstReference = try XCTUnwrap(mac.questionReference(for: TextExcerpt(text: first.quote, range: firstRange, context: "")))
        XCTAssertTrue(mac.listeningMarks.add(firstReference))
        try phone.countSlow(material: text.id, anchor: last)
        try phone.removeMark(material: text.id, anchor: second)
        await phone.sync()
        await mac.syncTextLibrary()
        await phone.sync()
        XCTAssertNil(mac.textSyncIssue)
        XCTAssertEqual(phone.marks(for: text.id).filter(\.needsReview).map(\.anchor.quote), [first.quote, last.quote])
        XCTAssertEqual(mac.listeningMarks.rows(for: .text, materialID: text.legacyKey)
            .filter(\.needsReview).map(\.passage), [first.quote, last.quote])
        XCTAssertEqual(mac.history.filter { $0.article.title == text.title }.count, 0)
        XCTAssertEqual(phone.favorites(for: text.id).first?.translation, "书摊开了。")

        let reopened = ReadingSyncStore(root: phoneRoot)
        XCTAssertEqual(reopened.folderName, folder.lastPathComponent)
        await reopened.sync()
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.marks(for: text.id), phone.marks(for: text.id))
        XCTAssertFalse(reopened.hasPendingChanges)
    }

    @MainActor
    func testCatalogAndRemotePositionKeepLocalReadingPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktop = ReadingSyncStore(root: root.appendingPathComponent("Mac"))
        let phone = ReadingSyncStore(root: root.appendingPathComponent("iPhone"))
        try desktop.connect(to: folder)
        try phone.connect(to: folder)
        var chapter = try ReadingMaterial(title: "Book", body: "The first sentence. The second sentence.")
        chapter.bookID = "book"
        chapter.chapter = "First"
        chapter.page = 1
        try desktop.record([.material(chapter)])
        await desktop.sync()
        await phone.sync()
        XCTAssertNil(phone.materials.first?.chapterCatalog)

        let now = Date()
        let local = ReadingProgress(offset: 0, completed: false, date: now)
        try phone.record([.progress(material: chapter.id, local)])
        chapter.chapterCatalog = [.init(page: 1, title: "First"), .init(page: 4, title: "Second")]
        let remote = ReadingProgress(offset: 20, completed: false, date: now.addingTimeInterval(1))
        try desktop.record([.material(chapter), .progress(material: chapter.id, remote)])
        await desktop.sync()
        await phone.sync()
        XCTAssertEqual(phone.materials.first?.chapterCatalog, chapter.chapterCatalog)
        XCTAssertEqual(phone.localProgress(for: chapter.id), local)
        XCTAssertEqual(phone.remoteProgress(for: chapter.id), remote)
    }

    @MainActor
    func testRapidPositionChangesNeverRewriteLibraryAndLatestSurvivesRelaunchAndSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let phoneRoot = root.appendingPathComponent("phone")
        let phone = ReadingSyncStore(root: phoneRoot, protectsLibrary: true)
        let book = try ReadingMaterial(title: "Large", body: String(repeating: "Another page of the story. ", count: 6000))
        try phone.record([.material(book)])
        let main = phoneRoot.appendingPathComponent("State.json")
        let original = try Data(contentsOf: main)
        for index in 1...500 {
            try phone.recordReadingPosition(material: book.id, progress: .init(offset: index, completed: index == 500))
        }
        XCTAssertTrue(phone.progressPending)
        await phone.sync() // Finishing an offline session also flushes.
        XCTAssertNil(phone.localSaveError)
        XCTAssertFalse(phone.progressPending)
        XCTAssertEqual(try Data(contentsOf: main), original)
        XCTAssertLessThan(try Data(contentsOf: phoneRoot.appendingPathComponent("Progress.json")).count, 2048)
        let reopened = ReadingSyncStore(root: phoneRoot, protectsLibrary: true)
        XCTAssertEqual(reopened.localProgress(for: book.id)?.offset, 500)
        XCTAssertEqual(reopened.localProgress(for: book.id)?.completed, true)
        let folder = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try reopened.connect(to: folder)
        await reopened.sync()
        let mac = ReadingSyncStore(root: root.appendingPathComponent("mac"))
        try mac.connect(to: folder)
        await mac.sync()
        XCTAssertEqual(mac.remoteProgress(for: book.id), reopened.localProgress(for: book.id))
        let file = folder.appendingPathComponent("SmartRead-v1/\(reopened.device).json")
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        for _ in 0..<5 { await reopened.sync() }
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp)
        XCTAssertEqual(try Data(contentsOf: main), original)
    }

    @MainActor
    func testCorruptLibraryIsPreservedAndBackupCanAcceptMarksAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = ReadingSyncStore(root: root, protectsLibrary: true)
        let book = try ReadingMaterial(title: "Backup", body: "A short story.")
        let anchor = try XCTUnwrap(ReadingAnchor.sentences(in: book.body).first)
        try phone.record([.material(book)])
        try phone.recordReadingPosition(material: book.id, progress: .init(offset: 2, completed: false))
        await phone.flushReadingPosition()
        let broken = Data("partial JSON".utf8)
        let main = root.appendingPathComponent("State.json")
        try broken.write(to: main)
        let reopened = ReadingSyncStore(root: root, protectsLibrary: true)
        XCTAssertTrue(reopened.canRestoreBackup)
        XCTAssertNotNil(reopened.error)
        XCTAssertThrowsError(try reopened.record([.mark(material: book.id, anchor, true)]))
        await reopened.sync()
        XCTAssertEqual(try Data(contentsOf: main), broken)
        try reopened.restoreLocalBackup()
        XCTAssertEqual(reopened.localProgress(for: book.id)?.offset, 2)
        let archive = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Recovery-") })
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("State.json")), broken)
        try reopened.record([.mark(material: book.id, anchor, true)])
        XCTAssertEqual(ReadingSyncStore(root: root, protectsLibrary: true).marks(for: book.id).first?.anchor, anchor)
    }

    @MainActor
    func testUnwritableJournalRetriesAndDamagedJournalCanRecoverWithoutLosingMarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = ReadingSyncStore(root: root, protectsLibrary: true)
        let book = try ReadingMaterial(title: "Retry", body: "One sentence.")
        let anchor = try XCTUnwrap(ReadingAnchor.sentences(in: book.body).first)
        try phone.record([.material(book), .mark(material: book.id, anchor, true)])
        let sidecar = root.appendingPathComponent("Progress.json")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
        try phone.recordReadingPosition(material: book.id, progress: .init(offset: 3, completed: true))
        await phone.flushReadingPosition()
        XCTAssertNotNil(phone.localSaveError)
        XCTAssertTrue(phone.progressPending)
        try FileManager.default.removeItem(at: sidecar)
        await phone.flushReadingPosition()
        XCTAssertNil(phone.localSaveError)
        XCTAssertFalse(phone.progressPending)
        try Data("broken journal".utf8).write(to: sidecar)
        let reopened = ReadingSyncStore(root: root, protectsLibrary: true)
        try reopened.restoreLocalBackup()
        XCTAssertEqual(reopened.marks(for: book.id).first?.anchor, anchor)
        try reopened.recordReadingPosition(material: book.id, progress: .init(offset: 4, completed: true))
        await reopened.flushReadingPosition()
        XCTAssertEqual(ReadingSyncStore(root: root, protectsLibrary: true).localProgress(for: book.id)?.offset, 4)
    }

    @MainActor
    func testRestoreMergesNewerChangesFromSameDevicesCloudFileBeforeRepublishing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let phoneRoot = root.appendingPathComponent("phone")
        let folder = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let phone = ReadingSyncStore(root: phoneRoot, protectsLibrary: true)
        try phone.connect(to: folder)
        let book = try ReadingMaterial(title: "Restore", body: "Read this sentence.")
        let anchor = try XCTUnwrap(ReadingAnchor.sentences(in: book.body).first)
        try phone.record([.material(book)])
        try phone.record([.mark(material: book.id, anchor, true)])
        await phone.sync()
        try Data("incomplete".utf8).write(to: phoneRoot.appendingPathComponent("State.json"))
        let restored = ReadingSyncStore(root: phoneRoot, protectsLibrary: true)
        try restored.restoreLocalBackup()
        XCTAssertTrue(restored.marks(for: book.id).isEmpty)
        await restored.sync(force: true)
        XCTAssertEqual(restored.marks(for: book.id).first?.anchor, anchor)
        let other = ReadingSyncStore(root: root.appendingPathComponent("other"))
        try other.connect(to: folder)
        await other.sync()
        XCTAssertEqual(other.marks(for: book.id).first?.anchor, anchor)
    }

    @MainActor
    func testIdleSkipsUnchangedSnapshotsButManualRefreshRechecksContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktop = ReadingSyncStore(root: root.appendingPathComponent("Mac"))
        let phone = ReadingSyncStore(root: root.appendingPathComponent("Phone"), protectsLibrary: true)
        try desktop.connect(to: folder)
        try phone.connect(to: folder)
        let book = try ReadingMaterial(title: "Idle", body: "Read the next page.")
        try desktop.record([.material(book)])
        await desktop.sync()
        let file = folder.appendingPathComponent("SmartRead-v1/\(desktop.device).json")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        await phone.sync()
        XCTAssertEqual(phone.materials, [book])
        let valid = try Data(contentsOf: file)
        // Keep all metadata in the fast-path fingerprint identical, changing only the bytes.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 0, count: valid.count))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        await phone.sync()
        XCTAssertNil(phone.error)
        await phone.sync(force: true)
        XCTAssertNotNil(phone.error)
        XCTAssertEqual(phone.materials, [book])
        try valid.write(to: file, options: .atomic)
        await phone.sync()
        XCTAssertNil(phone.error)
        try desktop.record([.progress(material: book.id, .init(offset: 9, completed: false))])
        await desktop.sync()
        await phone.sync()
        XCTAssertEqual(phone.remoteProgress(for: book.id)?.offset, 9)
    }

    @MainActor
    func testExistingMacImportAndRecordedRemovalsReachPreviouslySyncedMobileLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ArticleStore(root: root.appendingPathComponent("Mac"))
        let oldArticle = try Article.pasted("One test article remains on the network.", title: "Deleted before upgrade")
        let old = try ReadingMaterial(title: oldArticle.title, body: oldArticle.body,
                                      legacyKey: SavedReadingPosition.key(for: oldArticle))
        let before = ReadingSyncStore(root: store.textSyncDirectory)
        try before.connect(to: folder)
        try before.record([.material(old)], seed: true)
        await before.sync()
        let ipadRoot = root.appendingPathComponent("iPad")
        let ipad = ReadingSyncStore(root: ipadRoot, protectsLibrary: true)
        try ipad.connect(to: folder)
        await ipad.sync()
        XCTAssertEqual(ipad.materials.map(\.id), [old.id])

        // The older desktop build saved this article outside the sync database.
        let imported = try Article.pasted("This is the first sentence of a new interview.", title: "🥔访谈")
        try store.save(ArticleLibrary(current: imported))
        defaults.set([old.id], forKey: "textSyncHiddenHistory")
        let mac = ReaderModel(defaults: defaults, store: store)
        await mac.syncTextLibrary()
        await ipad.sync()
        XCTAssertNil(mac.textSyncIssue)
        XCTAssertEqual(ipad.materials.map(\.title), [imported.title])
        XCTAssertEqual(ipad.materials.first?.body, imported.body)
        XCTAssertEqual(ipad.materials.first.flatMap { ipad.progress(for: $0.id)?.offset }, 0)
        XCTAssertTrue(ipad.isHiddenFromHistory(old.historyKey))
        XCTAssertEqual(ipad.allMaterials.count, 2)

        let relaunched = ReadingSyncStore(root: ipadRoot, protectsLibrary: true)
        XCTAssertTrue(relaunched.isHiddenFromHistory(old.historyKey))
        XCTAssertEqual(relaunched.materials.map(\.title), [imported.title])
        XCTAssertNil(defaults.array(forKey: "textSyncHiddenHistory"))
    }

    @MainActor
    func testMacHistoryDeletionAndReimportSyncWhileAnOfflineReaderKeepsItsMarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mac = ReaderModel(defaults: defaults, store: ArticleStore(root: root.appendingPathComponent("Mac")))
        let body = "A reader keeps a useful sentence."
        try mac.importText(body, title: "First")
        try mac.importText("This is the current text.", title: "Current")
        await mac.connectTextSync(to: folder)
        let iphone = ReadingSyncStore(root: root.appendingPathComponent("iPhone"), protectsLibrary: true)
        let ipad = ReadingSyncStore(root: root.appendingPathComponent("iPad"), protectsLibrary: true)
        for device in [iphone, ipad] {
            try device.connect(to: folder)
            await device.sync()
        }
        let item = try XCTUnwrap(iphone.materials.first { $0.title == "First" })
        let anchor = try XCTUnwrap(ReadingAnchor.sentences(in: item.body).first)
        let favorite = ReadingFavorite(kind: "sentence", anchor: anchor, sentence: anchor.quote, translation: "测试译文")
        try iphone.record([.mark(material: item.id, anchor, true), .favorite(material: item.id, id: favorite.id, favorite)])
        let entry = try XCTUnwrap(mac.history.first { $0.article.title == item.title })
        try mac.deleteHistoryArticle(entry.id)
        await mac.syncTextLibrary()
        await ipad.sync()
        XCTAssertFalse(ipad.materials.contains { $0.id == item.id })

        try iphone.recordReadingPosition(material: item.id, progress: .init(offset: 2, completed: false))
        await iphone.sync()
        await ipad.sync()
        XCTAssertTrue(iphone.isHiddenFromHistory(item.historyKey))
        XCTAssertFalse(ipad.materials.contains { $0.id == item.id })

        try mac.importText(body, title: "First")
        await mac.syncTextLibrary()
        await ipad.sync()
        XCTAssertTrue(ipad.materials.contains { $0.id == item.id })
        XCTAssertEqual(ipad.marks(for: item.id).first?.anchor, anchor)
        XCTAssertEqual(ipad.favorites(for: item.id).first?.translation, favorite.translation)
    }

    @MainActor
    func testHistoryRemovalIsBookScopedAndPreservesTheV1ChangeList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mac = ReadingSyncStore(root: root.appendingPathComponent("Mac"))
        try mac.connect(to: folder)
        var first = try ReadingMaterial(title: "Reading book", body: "The first chapter.")
        first.bookID = "book-one"
        var second = try ReadingMaterial(title: "Reading book", body: "The second chapter.")
        second.bookID = "book-one"
        var unrelated = try ReadingMaterial(title: "Reading book", body: "Another book with the same title.")
        unrelated.bookID = "book-two"
        try mac.record([.material(first), .material(second), .material(unrelated)])
        try mac.setHistoryHidden(true, keys: [first.historyKey])
        await mac.sync()
        let mobile = ReadingSyncStore(root: root.appendingPathComponent("Mobile"))
        try mobile.connect(to: folder)
        await mobile.sync()
        XCTAssertEqual(mobile.materials.map(\.id), [unrelated.id])

        struct LegacySnapshot: Decodable {
            struct Change: Decodable { let value: ReadingSyncValue }
            let version: Int
            let changes: [Change]
        }
        let file = folder.appendingPathComponent("SmartRead-v1/\(mac.device).json")
        let legacy = try JSONDecoder().decode(LegacySnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(legacy.version, 1)
        XCTAssertEqual(legacy.changes.count, 3)
        XCTAssertEqual(Set(mobile.allMaterials.map(\.id)), Set([first.id, second.id, unrelated.id]))
    }
}
