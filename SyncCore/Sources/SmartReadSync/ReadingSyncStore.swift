import CryptoKit
import Foundation
import Observation

private struct ReadingChange: Codable, Equatable, Sendable {
    let clock: Int
    let writer: String
    let value: ReadingSyncValue

    func precedes(_ other: Self) -> Bool {
        if (clock == 0) != (other.clock == 0) { return clock == 0 }
        if case .progress(_, let old) = value, case .progress(_, let new) = other.value, old.date != new.date {
            return old.date < new.date
        }
        return (clock, writer) < (other.clock, other.writer)
    }
}

private struct ReadingHistoryChange: Codable, Equatable, Sendable {
    let key: String
    let hidden: Bool
    let date: Date
    let clock: Int
    let writer: String

    func precedes(_ other: Self) -> Bool {
        if (clock == 0) != (other.clock == 0) { return clock == 0 }
        return (date, clock, writer) < (other.date, other.clock, other.writer)
    }
}

private struct ReadingReplica: Codable, Sendable {
    var version = 1
    var device = UUID().uuidString.lowercased()
    var clock = 0
    var records: [String: ReadingChange] = [:]
    var local: [String: ReadingChange] = [:]
    var historyVisibility: [String: ReadingHistoryChange]?
    var localHistoryVisibility: [String: ReadingHistoryChange]?
    var localRevision: Int?
    var publishedRevision: Int?
}

private struct ProgressJournal: Codable, Sendable {
    var revision = 0
    var entries: [String: ReadingChange] = [:]
}

private actor ProgressDisk {
    private var written = -1

    func write(_ journal: ProgressJournal, to url: URL) throws {
        guard journal.revision > written else { return }
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        written = journal.revision
    }
}

@MainActor
@Observable
public final class ReadingSyncStore {
    private var replica = ReadingReplica()
    private let localURL: URL
    private let backupURL: URL
    private let progressURL: URL
    @ObservationIgnored private var lastReadableSnapshot: Data?
    private let protectsLibrary: Bool
    @ObservationIgnored private var journal = ProgressJournal()
    @ObservationIgnored private let progressDisk = ProgressDisk()
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    private var diskRevision = 0
    @ObservationIgnored private var fileStamps: [String: FileStamp] = [:]
    private var futureVersion = false
    private var positionSaveError: String?
    private var librarySaveError: String?
    public var localSaveError: String? { librarySaveError ?? positionSaveError }
    @ObservationIgnored private var markCache: [String: [ReadingMark]] = [:]
    private var markRevision = 0
    public var needsRecovery: Bool { localReadFailed }
    public var canRestoreBackup: Bool {
        localReadFailed && !futureVersion && FileManager.default.fileExists(atPath: backupURL.path)
    }
    public var syncDirectory: URL? { folder }
    public var progressPending: Bool {
        _ = revision
        return journal.revision > diskRevision
    }
    private let folderURL: URL
    private var folder: URL?
    private var needsScopedAccess = false
    private var localReadFailed = false
    public private(set) var revision = 0
    public private(set) var error: String?
    public private(set) var lastSync: Date?
    public private(set) var isSyncing = false
    public var folderName: String? { folder?.lastPathComponent }
    public var device: String { replica.device }
    private var hasLocalRecords: Bool {
        !replica.local.isEmpty || replica.localHistoryVisibility?.isEmpty == false
    }
    public var hasPendingChanges: Bool {
        hasLocalRecords && replica.publishedRevision != (replica.localRevision ?? 0)
    }

    public init(root: URL, protectsLibrary: Bool = false) {
        self.protectsLibrary = protectsLibrary
        backupURL = root.appendingPathComponent("State.backup.json")
        progressURL = root.appendingPathComponent("Progress.json")
        localURL = root.appendingPathComponent("State.json")
        folderURL = root.appendingPathComponent("Folder.bookmark")
        do {
            let data = try Data(contentsOf: localURL)
            replica = try JSONDecoder().decode(ReadingReplica.self, from: data)
            guard replica.version == 1 else {
                futureVersion = true
                throw ReadingSyncError.unsupportedVersion
            }
            if protectsLibrary { lastReadableSnapshot = data }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                localReadFailed = true
                self.error = "本机资料库缺失，可以从副本恢复。"
            }
        } catch {
            localReadFailed = true
            self.error = "本机资料无法读取：" + error.localizedDescription
        }
        if !localReadFailed {
            do {
                try loadProgress()
                if protectsLibrary, !FileManager.default.fileExists(atPath: backupURL.path),
                   FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.copyItem(at: localURL, to: backupURL)
                }
            } catch {
                localReadFailed = true
                self.error = "本机资料无法读取：" + error.localizedDescription
            }
        }
        if let data = try? Data(contentsOf: folderURL) {
            do {
                var stale = false
                #if os(macOS)
                let options: URL.BookmarkResolutionOptions = [.withoutUI]
                #else
                let options: URL.BookmarkResolutionOptions = [.withoutUI]
                #endif
                folder = try URL(resolvingBookmarkData: data, options: options, bookmarkDataIsStale: &stale)
                #if os(iOS)
                needsScopedAccess = true
                #endif
            } catch {
                if !localReadFailed { self.error = ReadingSyncError.unavailableFolder.localizedDescription }
            }
        }
    }

    private func loadProgress() throws {
        guard FileManager.default.fileExists(atPath: progressURL.path) else { return }
        let saved = try JSONDecoder().decode(ProgressJournal.self, from: Data(contentsOf: progressURL))
        for (key, change) in saved.entries {
            guard change.writer == replica.device, case .progress(let material, _) = change.value,
                  key == change.value.key, replica.records["material/" + material] != nil else { continue }
            if replica.records[key]?.precedes(change) != false { replica.records[key] = change }
            if replica.local[key]?.precedes(change) != false { replica.local[key] = change }
            replica.clock = max(replica.clock, change.clock)
        }
        replica.localRevision = max(replica.localRevision ?? 0, saved.revision)
        journal = saved
        diskRevision = saved.revision
    }

    public func restoreLocalBackup() throws {
        guard canRestoreBackup else { throw ReadingSyncError.invalidSnapshot }
        let data = try lastReadableSnapshot ?? Data(contentsOf: backupURL)
        let restored = try JSONDecoder().decode(ReadingReplica.self, from: data)
        guard restored.version == 1 else { throw ReadingSyncError.unsupportedVersion }
        let files = FileManager.default
        let archive = localURL.deletingLastPathComponent().appendingPathComponent("Recovery-" + UUID().uuidString)
        try files.createDirectory(at: archive, withIntermediateDirectories: true)
        for file in [localURL, progressURL] where files.fileExists(atPath: file.path) {
            try files.copyItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        }
        try data.write(to: localURL, options: .atomic)
        replica = restored
        lastReadableSnapshot = data
        do { try loadProgress() }
        catch {
            try files.removeItem(at: progressURL)
            journal = ProgressJournal()
            diskRevision = 0
        }
        fileStamps.removeAll()
        replica.publishedRevision = nil
        localReadFailed = false
        positionSaveError = nil
        librarySaveError = nil
        markCache.removeAll()
        markRevision += 1
        error = nil
        revision += 1
    }

    public func recordReadingPosition(material: String, progress: ReadingProgress) throws {
        guard !localReadFailed, replica.records["material/" + material] != nil else { throw ReadingSyncError.invalidSnapshot }
        let value = ReadingSyncValue.progress(material: material, progress)
        guard replica.records[value.key]?.value != value else { return }
        replica.clock += 1
        let change = ReadingChange(clock: replica.clock, writer: device, value: value)
        replica.records[value.key] = change
        replica.local[value.key] = change
        journal.entries[value.key] = change
        journal.revision = (replica.localRevision ?? 0) + 1
        replica.localRevision = journal.revision
        revision += 1
        if progressTask == nil {
            progressTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                progressTask = nil
                await flushReadingPosition()
            }
        }
    }

    public func flushReadingPosition() async {
        while !localReadFailed, diskRevision < journal.revision {
            let pending = journal
            do {
                try await progressDisk.write(pending, to: progressURL)
                diskRevision = max(diskRevision, pending.revision)
                positionSaveError = nil
            } catch {
                positionSaveError = "阅读位置尚未保存：" + error.localizedDescription
                return
            }
        }
    }

    public func connect(to url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #if os(iOS)
        guard accessed else { throw ReadingSyncError.unavailableFolder }
        #endif
        #if os(macOS)
        let data = try url.bookmarkData(options: .minimalBookmark)
        #else
        let data = try url.bookmarkData()
        #endif
        try FileManager.default.createDirectory(at: folderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: folderURL, options: .atomic)
        folder = url
        fileStamps.removeAll()
        var next = replica
        next.publishedRevision = nil
        if !localReadFailed, replica.publishedRevision != nil { try save(next) }
        #if os(iOS)
        needsScopedAccess = true
        #endif
        lastSync = nil
        if !localReadFailed { error = nil }
    }

    /// Publish the original once per content hash in the currently selected sync folder.
    public func publishPDFAsset(from localFile: URL, bookID: String) async throws {
        guard let folder else { throw ReadingSyncError.unavailableFolder }
        let scoped = needsScopedAccess
        try await Task.detached(priority: .utility) {
            try FolderExchange.publishPDF(localFile, bookID: bookID, folder: folder, scoped: scoped)
        }.value
        guard self.folder == folder else { throw CancellationError() }
    }

    /// Copy the original to an app-owned cache and verify its SHA-256 before use.
    /// Retry after iCloud makes the file available if this reports pdfPending.
    public func downloadPDFAsset(bookID: String, to destination: URL) async throws {
        guard let folder else { throw ReadingSyncError.unavailableFolder }
        let scoped = needsScopedAccess
        try await Task.detached(priority: .userInitiated) {
            try FolderExchange.downloadPDF(bookID, to: destination, folder: folder, scoped: scoped)
        }.value
        guard self.folder == folder else { throw CancellationError() }
    }

    public var materials: [ReadingMaterial] {
        allMaterials.filter { !isHiddenFromHistory($0.historyKey) && !isHiddenFromHistory("article/" + $0.id) }
    }

    public var allMaterials: [ReadingMaterial] {
        replica.records.values.compactMap {
            if case .material(let material) = $0.value { return material }
            return nil
        }.sorted { ($0.title, $0.page ?? 0, $0.id) < ($1.title, $1.page ?? 0, $1.id) }
    }

    public func isHiddenFromHistory(_ key: String) -> Bool {
        replica.historyVisibility?[key]?.hidden == true
    }

    public func setHistoryHidden(_ hidden: Bool, keys: Set<String>, seed: Bool = false) throws {
        guard !localReadFailed else { throw ReadingSyncError.invalidSnapshot }
        var next = replica
        var changes = next.historyVisibility ?? [:]
        var local = next.localHistoryVisibility ?? [:]
        for key in keys.sorted() where !seed || changes[key] == nil {
            if !seed { next.clock += 1 }
            let change = ReadingHistoryChange(key: key, hidden: hidden, date: seed ? .distantPast : .now,
                                              clock: seed ? 0 : next.clock, writer: next.device)
            changes[key] = change
            local[key] = change
        }
        guard local != (replica.localHistoryVisibility ?? [:]) else { return }
        next.historyVisibility = changes
        next.localHistoryVisibility = local
        next.localRevision = (replica.localRevision ?? 0) + 1
        try save(next)
    }

    public func progress(for material: String) -> ReadingProgress? {
        guard case .progress(_, let value)? = replica.records["progress/" + material]?.value else { return nil }
        return value
    }

    public func remoteProgress(for material: String) -> ReadingProgress? {
        guard let change = replica.records["progress/" + material], change.writer != device else { return nil }
        return progress(for: material)
    }

    public func localProgress(for material: String) -> ReadingProgress? {
        guard case .progress(_, let value)? = replica.local["progress/" + material]?.value else { return nil }
        return value
    }

    public func receivedMaterial(_ id: String) -> Bool {
        guard let change = replica.records["material/" + id] else { return false }
        return change.writer != device
    }

    public func favorites(for material: String) -> [ReadingFavorite] {
        replica.records.values.compactMap {
            if case .favorite(material, _, let favorite) = $0.value { return favorite }
            return nil
        }.sorted { $0.anchor.offset < $1.anchor.offset }
    }

    public func removedFavorites(for material: String) -> Set<String> {
        Set(replica.records.values.compactMap {
            if case .favorite(material, let id, nil) = $0.value { return id }
            return nil
        })
    }

    private func slowCounts(_ material: String, _ anchor: ReadingAnchor) -> [String: Int] {
        let prefix = "slow/" + ReadingSyncValue.markKey(material, anchor) + "/"
        return Dictionary(uniqueKeysWithValues: replica.records.compactMap { key, change in
            if key.hasPrefix(prefix), case .slow(_, _, let device, let count) = change.value {
                return (device, count)
            }
            return nil
        })
    }

    public func marks(for material: String) -> [ReadingMark] {
        _ = markRevision
        if let cached = markCache[material] { return cached }
        var anchors: [String: ReadingAnchor] = [:]
        var played: [String: [String: Int]] = [:]
        var manual: [String: Bool] = [:]
        var reviewed: [String: [String: Int]] = [:]
        for change in replica.records.values {
            switch change.value {
            case .mark(material, let anchor, let value):
                let key = ReadingSyncValue.markKey(material, anchor)
                anchors[key] = anchor
                manual[key] = value
            case .slow(material, let anchor, let device, let count):
                let key = ReadingSyncValue.markKey(material, anchor)
                if anchors[key] == nil { anchors[key] = anchor }
                played[key, default: [:]][device] = count
            case .reviewed(material, let anchor, let seen):
                reviewed[ReadingSyncValue.markKey(material, anchor)] = seen
            default: break
            }
        }
        let rows = anchors.map { key, anchor in
            let counts = played[key] ?? [:]
            let seen = reviewed[key] ?? [:]
            let total = counts.values.reduce(0, +)
            let done = counts.reduce(0) { $0 + min($1.value, seen[$1.key] ?? 0) }
            return ReadingMark(anchor: anchor, manuallyMarked: manual[key] ?? false, slowCount: total, reviewedCount: done)
        }.sorted { $0.anchor.offset < $1.anchor.offset }
        markCache[material] = rows
        return rows
    }

    public func record(_ values: [ReadingSyncValue], seed: Bool = false) throws {
        guard !localReadFailed else { throw ReadingSyncError.invalidSnapshot }
        var next = replica
        for value in values {
            let old = next.records[value.key]
            if old?.value == value || (seed && old != nil) { continue }
            if !seed { next.clock += 1 }
            let change = ReadingChange(clock: seed ? 0 : next.clock, writer: next.device, value: value)
            next.records[value.key] = change
            next.local[value.key] = change
        }
        if next.local != replica.local {
            next.localRevision = (replica.localRevision ?? 0) + 1
            try save(next)
        }
    }

    public func countSlow(material: String, anchor: ReadingAnchor) throws {
        let count = slowCounts(material, anchor)[device] ?? 0
        try record([.slow(material: material, anchor, device: device, count: count + 1)])
    }

    public func removeMark(material: String, anchor: ReadingAnchor) throws {
        try record([.mark(material: material, anchor, false),
                    .reviewed(material: material, anchor, seen: slowCounts(material, anchor))])
    }

    public func sync(force: Bool = false) async {
        await flushReadingPosition()
        guard !localReadFailed, !isSyncing, let folder else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let device = replica.device
            let scoped = needsScopedAccess
            let known = force ? [:] : fileStamps
            let exchange = try await Task.detached(priority: .utility) {
                try FolderExchange.read(from: folder, device: device, scoped: scoped, known: known)
            }.value
            guard self.folder == folder else { return }
            var next = replica
            for incoming in exchange.records {
                next.clock = max(next.clock, incoming.clock)
                let key = incoming.value.key
                if incoming.writer == device, next.local[key]?.precedes(incoming) ?? true {
                    next.local[key] = incoming
                }
                if let old = next.records[key], !old.precedes(incoming) { continue }
                next.records[key] = incoming
            }
            if !exchange.historyVisibility.isEmpty {
                var changes = next.historyVisibility ?? [:]
                var local = next.localHistoryVisibility ?? [:]
                for incoming in exchange.historyVisibility {
                    next.clock = max(next.clock, incoming.clock)
                    if incoming.writer == device, local[incoming.key]?.precedes(incoming) ?? true {
                        local[incoming.key] = incoming
                    }
                    if changes[incoming.key]?.precedes(incoming) ?? true { changes[incoming.key] = incoming }
                }
                next.historyVisibility = changes
                next.localHistoryVisibility = local
            }
            if next.clock != replica.clock || next.records != replica.records || next.local != replica.local ||
                next.historyVisibility != replica.historyVisibility || next.localHistoryVisibility != replica.localHistoryVisibility {
                try save(next)
            }
            fileStamps = exchange.stamps
            let ownName = device + ".json"
            if !exchange.ownDownloadNeeded, hasPendingChanges || (hasLocalRecords && (force || known[ownName] == nil || known[ownName] != fileStamps[ownName])) {
                let changes = Array(replica.local.values).sorted { $0.value.key < $1.value.key }
                let visibility = (replica.localHistoryVisibility ?? [:]).values.sorted { $0.key < $1.key }
                let publication = replica.localRevision ?? 0
                try await Task.detached(priority: .utility) {
                    try FolderExchange.write(changes, historyVisibility: visibility, to: folder, device: device, scoped: scoped)
                }.value
                guard self.folder == folder else { return }
                if replica.publishedRevision != publication {
                    if protectsLibrary {
                        replica.publishedRevision = publication
                    } else {
                        var published = replica
                        published.publishedRevision = publication
                        try save(published)
                    }
                }
            }
            if exchange.waiting == 0 && exchange.invalid == 0 {
                lastSync = .now
                error = nil
            } else {
                error = exchange.invalid > 0 ? ReadingSyncError.invalidSnapshot.localizedDescription : "等待 iCloud 下载记录，稍后自动再试。"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ next: ReadingReplica) throws {
        do {
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(next)
            if protectsLibrary {
                let previous = lastReadableSnapshot ?? data
                try previous.write(to: backupURL, options: .atomic)
            }
            try data.write(to: localURL, options: .atomic)
            if protectsLibrary { lastReadableSnapshot = data }
            librarySaveError = nil
        } catch {
            librarySaveError = "本机资料尚未保存：" + error.localizedDescription
            throw error
        }
        if next.records != replica.records {
            markCache.removeAll()
            markRevision += 1
        }
        if next.records != replica.records || next.historyVisibility != replica.historyVisibility { revision += 1 }
        replica = next
    }
}

private struct FileStamp: Equatable, Sendable {
    let date: Date
    let size: Int
    let inode: UInt64
}

private struct FolderExchange {
    let stamps: [String: FileStamp]
    let records: [ReadingChange]
    let historyVisibility: [ReadingHistoryChange]
    let ownDownloadNeeded: Bool
    let waiting: Int
    let invalid: Int

    private struct Snapshot: Codable {
        var version = 1
        let changes: [ReadingChange]
        // Keep the v1 change list readable by older SmartRead builds.
        let historyVisibility: [ReadingHistoryChange]?
    }

    private static func open<T>(_ folder: URL, scoped: Bool, _ action: (URL) throws -> T) throws -> T {
        let active = folder.startAccessingSecurityScopedResource()
        defer { if active { folder.stopAccessingSecurityScopedResource() } }
        guard !scoped || active else { throw ReadingSyncError.unavailableFolder }
        let root = folder.appendingPathComponent("SmartRead-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try action(root)
    }

    static func read(from folder: URL, device: String, scoped: Bool, known: [String: FileStamp]) throws -> Self {
        try open(folder, scoped: scoped) { root in
            let files = FileManager.default
            let urls = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])
            var records: [ReadingChange] = []
            var historyVisibility: [ReadingHistoryChange] = []
            var waiting = 0
            var invalid = 0
            var stamps: [String: FileStamp] = [:]
            var ownDownload = false
            for url in urls {
                let name = url.lastPathComponent
                let placeholder = name.hasSuffix(".json.icloud")
                let filename = placeholder ? String(name.dropFirst().dropLast(7)) : name
                guard filename.hasSuffix(".json"), let writer = UUID(uuidString: String(filename.dropLast(5))) else { continue }
                let canonical = root.appendingPathComponent(filename)
                let status = try? canonical.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                if placeholder || status == .notDownloaded || status == .downloaded {
                    try? files.startDownloadingUbiquitousItem(at: canonical)
                    waiting += 1
                    if writer.uuidString.lowercased() == device { ownDownload = true }
                    continue
                }
                do {
                    let attributes = try files.attributesOfItem(atPath: canonical.path)
                    let stamp: FileStamp?
                    if let date = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int,
                       let inode = attributes[.systemFileNumber] as? UInt64 {
                        stamp = FileStamp(date: date, size: size, inode: inode)
                    } else { stamp = nil }
                    if let stamp, known[filename] == stamp {
                        stamps[filename] = stamp
                        continue
                    }
                    let data = try coordinate(canonical, writing: false) { try Data(contentsOf: $0) }
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                    guard snapshot.version == 1 else { throw ReadingSyncError.unsupportedVersion }
                    guard snapshot.changes.allSatisfy({ $0.writer == writer.uuidString.lowercased() && $0.clock >= 0 && $0.clock < Int.max }) else {
                        throw ReadingSyncError.invalidSnapshot
                    }
                    let visibility = snapshot.historyVisibility ?? []
                    guard visibility.allSatisfy({
                        $0.writer == writer.uuidString.lowercased() && $0.clock >= 0 && $0.clock < Int.max &&
                        ($0.key.hasPrefix("article/") || $0.key.hasPrefix("book/"))
                    }) else { throw ReadingSyncError.invalidSnapshot }
                    stamps[filename] = stamp
                    records += snapshot.changes
                    historyVisibility += visibility
                } catch {
                    invalid += 1
                    if writer.uuidString.lowercased() == device { ownDownload = true }
                }
            }
            return Self(stamps: stamps, records: records, historyVisibility: historyVisibility,
                        ownDownloadNeeded: ownDownload, waiting: waiting, invalid: invalid)
        }
    }

    static func write(_ changes: [ReadingChange], historyVisibility: [ReadingHistoryChange],
                      to folder: URL, device: String, scoped: Bool) throws {
        guard !changes.isEmpty || !historyVisibility.isEmpty else { return }
        try open(folder, scoped: scoped) { root in
            let url = root.appendingPathComponent(device + ".json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Snapshot(changes: changes, historyVisibility: historyVisibility.isEmpty ? nil : historyVisibility))
            try coordinate(url, writing: true) { destination in
                if (try? Data(contentsOf: destination)) == data { return }
                try data.write(to: destination, options: .atomic)
            }
        }
    }

    private static func pdfAssetURL(_ bookID: String, in root: URL) throws -> URL {
        guard ReadingPDFPage.isValidBookID(bookID) else {
            throw ReadingSyncError.invalidPDF
        }
        return root.appendingPathComponent("PDFAssets", isDirectory: true).appendingPathComponent(bookID + ".pdf")
    }

    private static func isPDFPlaceholder(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
            || (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded
    }

    static func publishPDF(_ source: URL, bookID: String, folder: URL, scoped: Bool) throws {
        try open(folder, scoped: scoped) { root in
            let url = try pdfAssetURL(bookID, in: root)
            let files = FileManager.default
            if isPDFPlaceholder(url) || files.fileExists(atPath: url.path) { return }
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinate(url, writing: true) { destination in
                if !isPDFPlaceholder(destination) && !files.fileExists(atPath: destination.path) {
                    try copyVerifiedPDF(from: source, to: destination, bookID: bookID)
                }
            }
        }
    }

    static func downloadPDF(_ bookID: String, to destination: URL, folder: URL, scoped: Bool) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try pdfHash(destination) == bookID else { throw ReadingSyncError.invalidPDF }
            return
        }
        try open(folder, scoped: scoped) { root in
            let url = try pdfAssetURL(bookID, in: root)
            let files = FileManager.default
            guard !isPDFPlaceholder(url), files.fileExists(atPath: url.path) else {
                try? files.startDownloadingUbiquitousItem(at: url)
                throw ReadingSyncError.pdfPending
            }
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinate(url, writing: false) { source in
                try copyVerifiedPDF(from: source, to: destination, bookID: bookID)
            }
        }
    }

    private static func copyVerifiedPDF(from source: URL, to destination: URL, bookID: String) throws {
        let files = FileManager.default
        let staged = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".partial")
        defer { try? files.removeItem(at: staged) }
        try files.copyItem(at: source, to: staged)
        guard try pdfHash(staged) == bookID else { throw ReadingSyncError.invalidPDF }
        do { try files.moveItem(at: staged, to: destination) }
        catch let error as CocoaError where error.code == .fileWriteFileExists {
            guard try pdfHash(destination) == bookID else { throw ReadingSyncError.invalidPDF }
        }
    }

    private static func pdfHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func coordinate<T>(_ url: URL, writing: Bool, _ action: @escaping (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var failure: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { url in result = Result { try action(url) } }
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &failure, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &failure, byAccessor: accessor)
        }
        if let failure { throw failure }
        guard let result else { throw ReadingSyncError.unavailableFolder }
        return try result.get()
    }
}
