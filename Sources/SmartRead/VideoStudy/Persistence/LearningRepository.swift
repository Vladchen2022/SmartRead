import Foundation
import SQLite3

enum LearningRepositoryError: LocalizedError {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case read(String)

    var errorDescription: String? {
        switch self {
        case let .openDatabase(message):
            return "无法打开学习数据库：\(message)"
        case let .execute(message):
            return "数据库操作失败：\(message)"
        case let .prepare(message):
            return "无法准备数据库语句：\(message)"
        case let .bind(message):
            return "无法写入数据库参数：\(message)"
        case let .read(message):
            return "无法读取学习数据库：\(message)"
        }
    }
}

final class LearningRepository {
    private var database: OpaquePointer?
    private let databaseURL: URL
    private let isInMemory: Bool
    private(set) var migrationBackupURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static var defaultDatabaseURL: URL {
        applicationSupport.appending(path: "SmartRead/VideoStudy", directoryHint: .isDirectory)
            .appending(path: "videos.sqlite3")
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func openSmartReadLibrary(defaults: UserDefaults) throws -> LearningRepository {
        let legacyURL = applicationSupport.appending(path: "AEVP/aevp.sqlite3")
        let destination = defaultDatabaseURL
        if try importLegacyLibrary(from: legacyURL, to: destination),
           let preferences = defaults.persistentDomain(forName: "com.victorcloux.AEVP") {
            for (key, value) in preferences
            where key.hasPrefix("subtitleTrack.") || key.hasPrefix("subtitleCalibration.") || key == "englishReadingMode" {
                if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            }
        }
        return try LearningRepository(databaseURL: destination)
    }

    /// A SQLite snapshot includes committed changes that still live in the WAL.
    /// Keep the original library available to AEVP throughout the transition.
    @discardableResult
    static func importLegacyLibrary(from sourceURL: URL, to destination: URL) throws -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: sourceURL.path), !files.fileExists(atPath: destination.path) else { return false }
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appending(path: "video-import-\(UUID().uuidString).sqlite3")
        defer { try? files.removeItem(at: temporary) }

        var source: OpaquePointer?
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LearningRepositoryError.openDatabase("无法读取 AEVP 历史记录。")
        }
        sqlite3_busy_timeout(source, 2_000)
        try backupDatabase(source, to: temporary)
        do {
            try files.moveItem(at: temporary, to: destination)
            return true
        } catch where files.fileExists(atPath: destination.path) {
            return false
        }
    }

    init(databaseURL: URL = LearningRepository.defaultDatabaseURL, inMemory: Bool = false) throws {
        self.databaseURL = databaseURL
        self.isInMemory = inMemory
        if !inMemory {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(inMemory ? ":memory:" : databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(handle)
            throw LearningRepositoryError.openDatabase(message)
        }
        database = handle
        sqlite3_busy_timeout(handle, 5_000)

        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try migrateIfNeeded()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LearningRepositoryError.read(lastError)
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    @discardableResult
    func registerVideo(
        url: URL,
        displayName: String,
        durationMilliseconds: Int64
    ) throws -> VideoLearningRecord {
        let standardizedURL = url.standardizedFileURL
        let videoID = try upsertVideo(
            url: standardizedURL,
            displayName: displayName,
            durationMilliseconds: durationMilliseconds
        )
        let now = Date().timeIntervalSince1970
        let statement = try prepare(
            """
            UPDATE videos
            SET last_opened_at = ?, updated_at = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(now, at: 1, in: statement)
        try bind(now, at: 2, in: statement)
        try bind(videoID.uuidString, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LearningRepositoryError.execute(lastError)
        }
        guard let record = try videoRecord(forPath: standardizedURL.path) else {
            throw LearningRepositoryError.read("视频登记后无法读取。")
        }
        return record
    }

    func saveVideoState(_ draft: VideoLearningStateDraft) throws {
        let standardizedURL = draft.videoURL.standardizedFileURL
        let videoID = try upsertVideo(
            url: standardizedURL,
            displayName: draft.displayName,
            durationMilliseconds: draft.durationMilliseconds
        )
        let statement = try prepare(
            """
            UPDATE videos SET
                last_position_ms = ?,
                total_watched_ms = ?,
                playback_rate = ?,
                selected_audio_track_id = ?,
                english_subtitle_kind = ?,
                english_subtitle_path = ?,
                english_subtitle_track_id = ?,
                chinese_subtitle_kind = ?,
                chinese_subtitle_path = ?,
                chinese_subtitle_track_id = ?,
                updated_at = ?
            WHERE id = ?
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(max(0, draft.lastPositionMilliseconds), at: 1, in: statement)
        try bind(max(0, draft.totalWatchedMilliseconds), at: 2, in: statement)
        try bind(draft.playbackRate, at: 3, in: statement)
        try bind(draft.selectedAudioTrackID, at: 4, in: statement)
        try bind(draft.englishSubtitleKind.rawValue, at: 5, in: statement)
        try bind(draft.englishSubtitlePath, at: 6, in: statement)
        try bind(draft.englishSubtitleTrackID, at: 7, in: statement)
        try bind(draft.chineseSubtitleKind.rawValue, at: 8, in: statement)
        try bind(draft.chineseSubtitlePath, at: 9, in: statement)
        try bind(draft.chineseSubtitleTrackID, at: 10, in: statement)
        try bind(Date().timeIntervalSince1970, at: 11, in: statement)
        try bind(videoID.uuidString, at: 12, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LearningRepositoryError.execute(lastError)
        }

    }

    func videoRecord(for url: URL) throws -> VideoLearningRecord? {
        try videoRecord(forPath: url.standardizedFileURL.path)
    }

    func relinkVideo(_ record: VideoLearningRecord, to replacement: URL) throws {
        let url = replacement.standardizedFileURL
        guard !record.sourceExists, VideoFile.isSupported(url),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw LearningRepositoryError.bind("只能重新定位已失效的记录，且目标必须是可读取的视频。")
        }
        guard try videoID(forPath: url.path) == nil else {
            throw LearningRepositoryError.bind("这个文件已有独立记录，未覆盖任何进度。")
        }
        let statement = try prepare("UPDATE videos SET path = ?, display_name = ?, updated_at = ? WHERE id = ? AND path = ?")
        defer { sqlite3_finalize(statement) }
        try bind(url.path, at: 1, in: statement)
        try bind(url.lastPathComponent, at: 2, in: statement)
        try bind(Date().timeIntervalSince1970, at: 3, in: statement)
        try bind(record.id.uuidString, at: 4, in: statement)
        try bind(record.path, at: 5, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
            throw LearningRepositoryError.execute("原记录已变化，未更新路径。")
        }
    }

    func fetchRecentVideos(limit: Int = 20) throws -> [VideoLearningRecord] {
        let statement = try prepare(
            """
            SELECT
                id, path, display_name, duration_ms, last_position_ms,
                total_watched_ms, playback_rate, selected_audio_track_id,
                english_subtitle_kind, english_subtitle_path,
                english_subtitle_track_id, chinese_subtitle_kind,
                chinese_subtitle_path, chinese_subtitle_track_id,
                created_at, last_opened_at, updated_at
            FROM videos
            ORDER BY last_opened_at DESC, created_at DESC
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(Int64(max(1, limit)), at: 1, in: statement)

        var records: [VideoLearningRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw LearningRepositoryError.read(lastError)
            }
            if let record = readVideoRecord(from: statement) {
                records.append(record)
            }
        }
        return records
    }


    @discardableResult
    func recordInteraction(
        _ draft: LearningActivityDraft,
        at date: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent,
        modelID: String = ""
    ) throws -> LearningActivity {
        let dayKey = LearningDay.key(for: date, timeZone: timeZone)
        try execute("BEGIN IMMEDIATE")
        do {
            let existing = try fetchActivities(dayKey: dayKey).first {
                $0.kind == draft.kind && $0.identity == draft.identity
            }
            var entry = LearningActivity(
                id: existing?.id ?? UUID(), dayKey: dayKey,
                timeZoneIdentifier: existing?.timeZoneIdentifier ?? timeZone.identifier,
                kind: draft.kind, identity: draft.identity,
                videoPath: draft.videoURL.standardizedFileURL.path,
                english: draft.english, chinese: draft.chinese,
                previousEnglish: draft.previousEnglish, nextEnglish: draft.nextEnglish,
                startMilliseconds: draft.startMilliseconds, endMilliseconds: draft.endMilliseconds,
                word: draft.word?.text, wordStartUTF16: draft.word?.range.location,
                wordLengthUTF16: draft.word?.range.length,
                firstTriggeredAt: existing?.firstTriggeredAt ?? date,
                lastTriggeredAt: date, interactionCount: (existing?.interactionCount ?? 0) + 1,
                generation: (existing?.generation ?? 0) + 1, status: .pending,
                modelID: modelID, wordExplanation: existing?.wordExplanation,
                sentenceAnalysis: existing?.sentenceAnalysis, errorMessage: nil,
                lastSucceededAt: existing?.lastSucceededAt,
                lastSucceededModelID: existing?.lastSucceededModelID,
                sourceStartMilliseconds: draft.sourceStartMilliseconds,
                englishOffsetMilliseconds: draft.englishOffsetMilliseconds,
                chineseOffsetMilliseconds: draft.chineseOffsetMilliseconds,
                validationVersion: existing?.validationVersion,
                sourceContext: draft.sourceContext,
                englishTiming: draft.englishTiming,
                chineseTiming: draft.chineseTiming
            )
            // Each new answer requires fresh confirmation; never inherit the
            // authorization of an older saved answer for the same source.
            // A repeated request has its own generation. A late older response
            // must not overwrite the result of a newer deliberate click.
            entry.status = .pending
            try writeActivity(entry)
            try execute("COMMIT")
            return entry
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func finishInteraction(
        _ handle: LearningActivityHandle,
        status: LearningActivityStatus,
        word: WordExplanation? = nil,
        sentence: SentenceAnalysis? = nil,
        modelID: String = "",
        error: String? = nil,
        completedAt: Date = Date()
    ) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            guard var entry = try fetchActivities(dayKey: handle.dayKey).first(where: { $0.id == handle.id }),
                  entry.generation == handle.generation else {
                try execute("COMMIT")
                return false
            }
            entry.status = status
            if status == .completed {
                guard (entry.kind == .word && word?.isValid == true && sentence == nil)
                    || (entry.kind == .sentence && sentence != nil && word == nil) else {
                    throw LearningRepositoryError.bind("完成状态缺少与记录类型对应的解析。")
                }
                entry.wordExplanation = word
                entry.sentenceAnalysis = sentence
                entry.lastSucceededAt = completedAt
                entry.validationVersion = AIValidationPolicy.version
                entry.lastSucceededModelID = modelID.isEmpty ? entry.modelID : modelID
            }
            entry.errorMessage = error
            if !modelID.isEmpty { entry.modelID = modelID }
            try writeActivity(entry)
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func fetchActivities(dayKey: String? = nil) throws -> [LearningActivity] {
        let sql = "SELECT payload_json FROM learning_activities"
            + (dayKey == nil ? "" : " WHERE day_key = ?")
            + " ORDER BY first_triggered_at ASC, id ASC"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let dayKey { try bind(dayKey, at: 1, in: statement) }
        var entries: [LearningActivity] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw LearningRepositoryError.read(lastError) }
            // Do not silently discard a malformed record and then mark its day synced.
            entries.append(try decoder.decode(LearningActivity.self, from: Data(string(at: 0, in: statement).utf8)))
        }
        return entries
    }

    func pendingExportDays() throws -> [String] {
        let statement = try prepare("SELECT DISTINCT day_key FROM learning_activities WHERE export_pending = 1 ORDER BY day_key")
        defer { sqlite3_finalize(statement) }
        var days: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw LearningRepositoryError.read(lastError) }
            let day = string(at: 0, in: statement)
            if try !fetchConfirmedActivities(dayKey: day).isEmpty { days.append(day) }
        }
        return days
    }

    func markDayExported(_ dayKey: String) throws {
        let statement = try prepare("UPDATE learning_activities SET export_pending = 0 WHERE day_key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(dayKey, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LearningRepositoryError.execute(lastError) }
    }

    func markAllActivitiesForExport() throws {
        for entry in try fetchActivities() where entry.confirmedAt != nil { try writeActivity(entry) }
    }

    func pendingConfirmedActivities() throws -> [LearningActivity] {
        let statement = try prepare("SELECT payload_json FROM learning_activities WHERE export_pending = 1 ORDER BY day_key, first_triggered_at")
        defer { sqlite3_finalize(statement) }
        var result: [LearningActivity] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw LearningRepositoryError.read(lastError) }
            let entry = try decoder.decode(LearningActivity.self, from: Data(string(at: 0, in: statement).utf8))
            if entry.confirmedAt != nil, entry.status == .completed { result.append(entry) }
        }
    }

    func markExported(_ snapshot: [LearningActivity]) throws {
        let pending = Dictionary(uniqueKeysWithValues: try pendingConfirmedActivities().map { ($0.id, $0) })
        let statement = try prepare("UPDATE learning_activities SET export_pending = 0 WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        for entry in snapshot where pending[entry.id] == entry {
            sqlite3_reset(statement)
            try bind(entry.id.uuidString, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw LearningRepositoryError.execute(lastError) }
        }
    }

    func queueConfirmedHistory(to destination: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for var entry in try fetchActivities() where entry.confirmedAt != nil && entry.status == .completed {
                entry.exportDestination = destination
                try writeActivity(entry)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func fetchConfirmedActivities(dayKey: String) throws -> [LearningActivity] {
        try fetchActivities(dayKey: dayKey).filter { $0.confirmedAt != nil && $0.status == .completed }
    }

    @discardableResult
    func confirmInteraction(_ handle: LearningActivityHandle, at date: Date = Date(), destination: String? = nil) throws -> Bool {
        guard var entry = try fetchActivities(dayKey: handle.dayKey).first(where: { $0.id == handle.id }),
              entry.generation == handle.generation, entry.status == .completed else { return false }
        entry.confirmedAt = date
        entry.exportDestination = destination
        try writeActivity(entry)
        return true
    }

    private func writeActivity(_ entry: LearningActivity) throws {
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        let statement = try prepare("""
            INSERT INTO learning_activities
                (id, day_key, kind, identity_key, first_triggered_at, payload_json, export_pending)
            VALUES (?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(id) DO UPDATE SET
                payload_json = excluded.payload_json, export_pending = 1
            """)
        defer { sqlite3_finalize(statement) }
        try bind(entry.id.uuidString, at: 1, in: statement)
        try bind(entry.dayKey, at: 2, in: statement)
        try bind(entry.kind.rawValue, at: 3, in: statement)
        try bind(entry.identity, at: 4, in: statement)
        try bind(entry.firstTriggeredAt.timeIntervalSince1970, at: 5, in: statement)
        try bind(json, at: 6, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LearningRepositoryError.execute(lastError) }
    }

    private func migrateIfNeeded() throws {
        let version = try schemaVersion()
        guard version <= 5 else { throw LearningRepositoryError.read("数据库版本高于本应用支持的版本。") }
        guard version < 5 else { return }
        if version > 0, !isInMemory { try backupBeforeMigration() }
        try execute("BEGIN IMMEDIATE")
        do {
            if version == 0 {
                try execute("""
                    CREATE TABLE videos (
                        id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL UNIQUE,
                        display_name TEXT NOT NULL, duration_ms INTEGER NOT NULL,
                        created_at REAL NOT NULL
                    )
                    """)
            }
            if version < 2 {
                for column in [
                    "last_position_ms INTEGER NOT NULL DEFAULT 0",
                    "total_watched_ms INTEGER NOT NULL DEFAULT 0",
                    "playback_rate REAL NOT NULL DEFAULT 1",
                    "selected_audio_track_id INTEGER",
                    "english_subtitle_kind TEXT NOT NULL DEFAULT 'automatic'",
                    "english_subtitle_path TEXT", "english_subtitle_track_id INTEGER",
                    "chinese_subtitle_kind TEXT NOT NULL DEFAULT 'automatic'",
                    "chinese_subtitle_path TEXT", "chinese_subtitle_track_id INTEGER",
                    "last_opened_at REAL NOT NULL DEFAULT 0",
                    "updated_at REAL NOT NULL DEFAULT 0"
                ] { try execute("ALTER TABLE videos ADD COLUMN \(column)") }
                try execute("UPDATE videos SET last_opened_at = created_at, updated_at = created_at WHERE last_opened_at = 0")
            }
            try execute("CREATE INDEX IF NOT EXISTS videos_last_opened_idx ON videos(last_opened_at DESC)")
            // These features are retired, not hidden. A complete SQLite backup
            // above preserves their historical data without any active task code.
            try execute("DROP TABLE IF EXISTS daily_review_items")
            try execute("DROP TABLE IF EXISTS review_days")
            try execute("DROP TABLE IF EXISTS favorites")
            try execute("DROP TABLE IF EXISTS sentence_records")
            try execute("""
                CREATE TABLE learning_activities (
                    id TEXT PRIMARY KEY NOT NULL, day_key TEXT NOT NULL,
                    kind TEXT NOT NULL, identity_key TEXT NOT NULL,
                    first_triggered_at REAL NOT NULL, payload_json TEXT NOT NULL,
                    export_pending INTEGER NOT NULL DEFAULT 1,
                    UNIQUE(day_key, kind, identity_key)
                )
                """)
            try execute("CREATE INDEX learning_activities_pending_idx ON learning_activities(export_pending, day_key)")
            try execute("PRAGMA user_version = 5")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func backupBeforeMigration() throws {
        let destination = databaseURL.deletingLastPathComponent()
            .appending(path: "videos-before-migration-\(UUID().uuidString).sqlite3")
        try Self.backupDatabase(database, to: destination)
        migrationBackupURL = destination
    }

    private static func backupDatabase(_ source: OpaquePointer?, to destination: URL) throws {
        var target: OpaquePointer?
        defer { sqlite3_close(target) }
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let target else { throw LearningRepositoryError.openDatabase("无法创建迁移前备份。") }
        sqlite3_busy_timeout(target, 2_000)
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw LearningRepositoryError.execute("无法初始化迁移前备份。")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw LearningRepositoryError.execute("迁移前备份未完成，已停止迁移。")
        }
    }

    private func upsertVideo(
        url: URL,
        displayName: String,
        durationMilliseconds: Int64
    ) throws -> UUID {
        if let existing = try videoID(forPath: url.path) {
            let statement = try prepare(
                """
                UPDATE videos SET
                    display_name = ?,
                    duration_ms = CASE WHEN ? > 0 THEN ? ELSE duration_ms END
                WHERE id = ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(displayName, at: 1, in: statement)
            try bind(durationMilliseconds, at: 2, in: statement)
            try bind(durationMilliseconds, at: 3, in: statement)
            try bind(existing.uuidString, at: 4, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw LearningRepositoryError.execute(lastError)
            }
            return existing
        }

        let id = UUID()
        let statement = try prepare(
            """
            INSERT INTO videos (
                id, path, display_name, duration_ms, created_at,
                last_opened_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        try bind(id.uuidString, at: 1, in: statement)
        try bind(url.path, at: 2, in: statement)
        try bind(displayName, at: 3, in: statement)
        try bind(durationMilliseconds, at: 4, in: statement)
        try bind(now, at: 5, in: statement)
        try bind(now, at: 6, in: statement)
        try bind(now, at: 7, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LearningRepositoryError.execute(lastError)
        }
        return id
    }

    private func videoID(forPath path: String) throws -> UUID? {
        let statement = try prepare("SELECT id FROM videos WHERE path = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, in: statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw LearningRepositoryError.read(lastError)
        }
        return UUID(uuidString: string(at: 0, in: statement))
    }

    private func videoRecord(forPath path: String) throws -> VideoLearningRecord? {
        let statement = try prepare(
            """
            SELECT
                id, path, display_name, duration_ms, last_position_ms,
                total_watched_ms, playback_rate, selected_audio_track_id,
                english_subtitle_kind, english_subtitle_path,
                english_subtitle_track_id, chinese_subtitle_kind,
                chinese_subtitle_path, chinese_subtitle_track_id,
                created_at, last_opened_at, updated_at
            FROM videos
            WHERE path = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, in: statement)

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return nil
        }
        guard result == SQLITE_ROW else {
            throw LearningRepositoryError.read(lastError)
        }
        return readVideoRecord(from: statement)
    }

    private func readVideoRecord(
        from statement: OpaquePointer
    ) -> VideoLearningRecord? {
        guard let id = UUID(uuidString: string(at: 0, in: statement)) else {
            return nil
        }

        return VideoLearningRecord(
            id: id,
            path: string(at: 1, in: statement),
            displayName: string(at: 2, in: statement),
            durationMilliseconds: sqlite3_column_int64(statement, 3),
            lastPositionMilliseconds: sqlite3_column_int64(statement, 4),
            totalWatchedMilliseconds: sqlite3_column_int64(statement, 5),
            playbackRate: sqlite3_column_double(statement, 6),
            selectedAudioTrackID: optionalInt32(at: 7, in: statement),
            englishSubtitleKind: StoredSubtitleKind(
                rawValue: string(at: 8, in: statement)
            ) ?? .automatic,
            englishSubtitlePath: optionalString(at: 9, in: statement),
            englishSubtitleTrackID: optionalInt(at: 10, in: statement),
            chineseSubtitleKind: StoredSubtitleKind(
                rawValue: string(at: 11, in: statement)
            ) ?? .automatic,
            chineseSubtitlePath: optionalString(at: 12, in: statement),
            chineseSubtitleTrackID: optionalInt(at: 13, in: statement),
            createdAt: Date(
                timeIntervalSince1970: sqlite3_column_double(statement, 14)
            ),
            lastOpenedAt: Date(
                timeIntervalSince1970: sqlite3_column_double(statement, 15)
            ),
            updatedAt: Date(
                timeIntervalSince1970: sqlite3_column_double(statement, 16)
            )
        )
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorMessage)
            throw LearningRepositoryError.execute(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LearningRepositoryError.prepare(lastError)
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw LearningRepositoryError.bind(lastError)
        }
    }

    private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw LearningRepositoryError.bind(lastError)
        }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw LearningRepositoryError.bind(lastError)
        }
    }

    private func bind(
        _ value: String?,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw LearningRepositoryError.bind(lastError)
            }
            return
        }
        try bind(value, at: index, in: statement)
    }

    private func bind(
        _ value: Int?,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw LearningRepositoryError.bind(lastError)
            }
            return
        }
        try bind(Int64(value), at: index, in: statement)
    }

    private func bind(
        _ value: Int32?,
        at index: Int32,
        in statement: OpaquePointer
    ) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw LearningRepositoryError.bind(lastError)
            }
            return
        }
        try bind(Int64(value), at: index, in: statement)
    }

    private func string(at index: Int32, in statement: OpaquePointer) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func optionalString(
        at index: Int32,
        in statement: OpaquePointer
    ) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return string(at: index, in: statement)
    }

    private func optionalInt(
        at index: Int32,
        in statement: OpaquePointer
    ) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func optionalInt32(
        at index: Int32,
        in statement: OpaquePointer
    ) -> Int32? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int(statement, index)
    }

    private func optionalDate(
        at index: Int32,
        in statement: OpaquePointer
    ) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Date(
            timeIntervalSince1970: sqlite3_column_double(statement, index)
        )
    }

    private var lastError: String {
        guard let database else { return "数据库连接不可用。" }
        return String(cString: sqlite3_errmsg(database))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
