import Foundation
import Observation

@MainActor
@Observable
final class WeeklyFavoriteSync {
    static let folderName = "03-4 英语泛读沉淀"

    private static let folderKey = "weeklyFavoritesFolder"
    private static let automaticKey = "weeklyFavoritesAutomatic"

    private(set) var folder: URL?
    private(set) var automatic: Bool
    private(set) var isWorking = false
    private(set) var status: String?
    private var pending: [String: WeeklyFavoriteJob] = [:]
    private let queueFile: URL
    private let defaults: UserDefaults
    private var queueReadFailed = false

    var pendingCount: Int { pending.count }
    var previousDestinationCount: Int { pending.values.filter { $0.folder != folder }.count }
    var hasPreviousDestination: Bool { previousDestinationCount > 0 }

    init(defaults: UserDefaults, queueFile: URL) {
        self.defaults = defaults
        self.queueFile = queueFile
        folder = defaults.url(forKey: Self.folderKey)
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        do {
            let data = try Data(contentsOf: queueFile)
            let jobs = try JSONDecoder().decode([WeeklyFavoriteJob].self, from: data)
            guard jobs.allSatisfy(\.hasOneFavorite) else { throw ReaderError.message("待写入条目缺少收藏内容。") }
            pending = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // There is no queue until the first export.
        } catch {
            queueReadFailed = true
            status = "无法读取泛读收藏的待写入记录。\(error.localizedDescription)"
        }
    }

    func setFolder(_ url: URL, movingPending: Bool = false) {
        guard !isWorking else { return }
        do {
            let selected = try WeeklyFavoriteNotes.directory(url)
            if movingPending {
                guard !queueReadFailed else { throw ReaderError.message("待写入队列无法读取。") }
                var moved: [String: WeeklyFavoriteJob] = [:]
                for var job in pending.values {
                    job.folder = selected
                    moved[job.id] = job
                }
                try saveQueue(moved)
            }
            folder = selected
            defaults.set(selected, forKey: Self.folderKey)
            if !queueReadFailed { status = nil }
            resume()
        } catch {
            status = "无法使用所选目录。\(error.localizedDescription)"
        }
    }

    func setAutomatic(_ enabled: Bool) {
        automatic = enabled
        defaults.set(enabled, forKey: Self.automaticKey)
        resume()
    }

    // Stage before the favorite is committed. The worker confirms the favorite is still saved
    // before writing, including after a crash between creating the job and saving the favorite.
    func stage(favorite: LearningFavorite, record: LearningRecord, file: URL, webURL: URL?) {
        guard let folder else { return }
        stage(WeeklyFavoriteJob(favorite: favorite, record: record, recordFile: file,
                                folder: folder, period: .init(), webURL: webURL))
    }

    func stage(question: AssistantQuestionFavorite, file: URL) {
        guard let folder, let origin = question.weeklyOrigin else { return }
        stage(WeeklyFavoriteJob(question: question, origin: origin, recordFile: file, folder: folder, period: .init()))
    }

    private func stage(_ job: WeeklyFavoriteJob) {
        do {
            try enqueue([job])
        } catch {
            status = "无法排队写入 Obsidian。收藏仍保存在 SmartRead，可用「补写本周已有收藏」重试。\(error.localizedDescription)"
        }
    }

    func reportUnresolvedQuestion(_ error: Error) {
        status = "问答已保存在 SmartRead。无法读取泛读来源，可用「补写本周已有收藏」重试。\(error.localizedDescription)"
    }

    func resume() {
        if automatic { retry() }
    }

    func retry() {
        guard !isWorking, !queueReadFailed, !pending.isEmpty else { return }
        writePending(pending, backfill: false)
    }

    func discardPending(favoriteID: String) {
        let remaining = pending.filter { $0.value.favoriteID != favoriteID }
        guard remaining.count != pending.count else { return }
        do { try saveQueue(remaining) }
        catch { status = "无法更新待写入记录。\(error.localizedDescription)" }
    }

    func backfill(records: ImportedLearningRecords, articleURLs: [URL: URL], questionFile: URL,
                  questions: [(AssistantQuestionFavorite, WeeklyFavoriteOrigin)], unreadableQuestions: Int) {
        guard let folder, !isWorking, !queueReadFailed else { return }
        let pendingAtStart = Set(pending.keys)
        isWorking = true
        status = "正在查找本周收藏…"
        let scan = Task.detached(priority: .utility) {
            let period = WeeklyFavoritePeriod()
            let week = period.week(containing: .now)
            let sampleFile = records.file(for: .sample)
            var jobs = questions.filter { week.contains($0.0.savedAt) }.map { favorite, origin in
                WeeklyFavoriteJob(question: favorite, origin: origin, recordFile: questionFile, folder: folder, period: period)
            }
            var unreadable = unreadableQuestions
            for file in try records.favoriteRecordFiles() where file != sampleFile {
                guard let record = try? LearningRecordStore.read(file) else {
                    unreadable += 1
                    continue
                }
                guard record.sourceId == nil else { continue }
                jobs += record.favorites.filter { $0.createdAt >= week.start && $0.createdAt < week.end }.map {
                    WeeklyFavoriteJob(favorite: $0, record: record, recordFile: file, folder: folder, period: period,
                                      webURL: articleURLs[file])
                }
            }
            return (jobs, unreadable)
        }
        Task {
            do {
                let (jobs, unreadable) = try await scan.value
                try enqueue(jobs)
                guard !jobs.isEmpty else {
                    isWorking = false
                    status = unreadable == 0 ? "本周没有可补写的收藏。" : "没有找到可补写的收藏，另有 \(unreadable) 份记录无法读取。"
                    if pending.keys.contains(where: { !pendingAtStart.contains($0) }) { resume() }
                    return
                }
                let ids = Set(jobs.map(\.id))
                writePending(pending.filter { ids.contains($0.key) }, backfill: true, unreadable: unreadable,
                             retryNewSince: pendingAtStart.union(ids))
            } catch {
                isWorking = false
                status = "无法补写本周收藏。\(error.localizedDescription)"
                if pending.keys.contains(where: { !pendingAtStart.contains($0) }) { resume() }
            }
        }
    }

    private func enqueue(_ jobs: [WeeklyFavoriteJob]) throws {
        guard !queueReadFailed else { throw ReaderError.message("待写入记录无法读取。") }
        var next = pending
        for job in jobs where next[job.id] == nil { next[job.id] = job }
        guard next.count != pending.count else { return }
        try saveQueue(next)
    }

    private func saveQueue(_ jobs: [String: WeeklyFavoriteJob]) throws {
        try FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(jobs.values)).write(to: queueFile, options: .atomic)
        pending = jobs
    }

    private func writePending(_ batch: [String: WeeklyFavoriteJob], backfill: Bool, unreadable: Int = 0,
                              retryNewSince previousIDs: Set<String>? = nil) {
        isWorking = true
        status = "正在写入泛读周记…"
        let previousIDs = previousIDs ?? Set(batch.keys)
        let write = Task.detached(priority: .utility) { Self.write(Array(batch.values)) }
        Task {
            let result = await write.value
            var remaining = pending
            for id in result.finished { remaining.removeValue(forKey: id) }
            do {
                if remaining.count != pending.count { try saveQueue(remaining) }
                if let error = result.firstError {
                    status = "还有 \(pendingCount) 条待写入。\(error)"
                } else if result.appended > 0 {
                    status = "已追加 \(result.appended) 条收藏。"
                } else if backfill {
                    status = "本周收藏已是最新。"
                } else {
                    status = nil
                }
                if unreadable > 0 { status = (status ?? "") + "另有 \(unreadable) 份收藏记录无法读取。" }
                isWorking = false
                if pending.keys.contains(where: { !previousIDs.contains($0) }) { resume() }
            } catch {
                isWorking = false
                status = "无法更新待写入记录。重试时会跳过周记中已有的条目。\(error.localizedDescription)"
            }
        }
    }

    private struct BatchResult: Sendable {
        var finished: [String] = []
        var appended = 0
        var firstError: String?
    }

    nonisolated private static func write(_ jobs: [WeeklyFavoriteJob]) -> BatchResult {
        var result = BatchResult()
        let byFile = Dictionary(grouping: jobs, by: \.recordFile)
        var active: [WeeklyFavoriteJob] = []
        for (file, entries) in byFile {
            do {
                if entries.first?.question != nil {
                    let favorites = Dictionary(try AssistantQuestionFavorites.read(file).map { ($0.id, $0) },
                                               uniquingKeysWith: { first, _ in first })
                    for var job in entries {
                        if let id = job.question?.id, let current = favorites[id],
                           current.mode == .text, current.reference?.hasOriginalPassage == true {
                            job.question = current
                            active.append(job)
                        } else { result.finished.append(job.id) }
                    }
                } else {
                    let record = try LearningRecordStore.read(file)
                    let favorites = Dictionary(record.favorites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for var job in entries {
                        if let id = job.favorite?.id, record.sourceId == nil, let current = favorites[id] {
                            job.favorite = current
                            active.append(job)
                        } else { result.finished.append(job.id) }
                    }
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                result.finished += entries.map(\.id)
            } catch {
                if result.firstError == nil { result.firstError = error.localizedDescription }
            }
        }
        for (note, entries) in Dictionary(grouping: active, by: \.noteURL) {
            do {
                result.appended += try WeeklyFavoriteNotes.append(entries, to: note)
                result.finished += entries.map(\.id)
            } catch {
                if result.firstError == nil {
                    result.firstError = "\(note.deletingLastPathComponent().lastPathComponent) · \(error.localizedDescription)"
                }
            }
        }
        return result
    }
}
