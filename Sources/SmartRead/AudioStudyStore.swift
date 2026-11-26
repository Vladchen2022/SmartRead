import AVFoundation
import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum AudioStudyFormat: String, Codable {
    case mp3, mp4

    static let contentTypes: [UTType] = [.mp3, .mpeg4Movie]

    init?(url: URL) {
        guard url.isFileURL else { return nil }
        self.init(rawValue: url.pathExtension.lowercased())
    }
}

struct AudioStudyCue: Codable, Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    static func normalized(_ cues: [Self], duration: Double) -> [Self] {
        var result: [Self] = []
        let timedCues = cues.filter { $0.start.isFinite && $0.end.isFinite }
        for var cue in timedCues.sorted(by: { $0.start < $1.start }) {
            cue.start = max(result.last?.end ?? 0, cue.start)
            cue.end = min(duration, cue.end)
            cue.text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cue.end > cue.start, !cue.text.isEmpty else { continue }
            result.append(cue)
        }
        return result
    }
}

struct AudioStudyEntry: Codable, Identifiable {
    let id: UUID
    let title: String
    let format: AudioStudyFormat
    let duration: Double
    var mediaDigest: String?
    var cues: [AudioStudyCue]?
    var position: Double = 0
    var lastOpened = Date()

    func playbackRange(for index: Int) -> Range<Double>? {
        guard let cues, cues.indices.contains(index) else { return nil }
        let cue = cues[index]
        let previousEnd = index > 0 ? cues[index - 1].end : 0
        let nextStart = index + 1 < cues.count ? cues[index + 1].start : duration
        let start = max(previousEnd, cue.start - 0.08)
        let end = min(nextStart, cue.end + 0.12)
        guard end > start else { return nil }
        return start..<end
    }

    func cueIndex(at time: Double) -> Int? {
        guard let cues, !cues.isEmpty else { return nil }
        var first = 0
        var end = cues.count
        while first < end {
            let mid = (first + end) / 2
            if cues[mid].start <= time { first = mid + 1 }
            else { end = mid }
        }
        return first == 0 ? nil : first - 1
    }

    func nextPlayableCue(at time: Double) -> Int? {
        guard let cues, !cues.isEmpty else { return nil }
        guard let index = cueIndex(at: time) else { return 0 }
        if time < cues[index].end { return index }
        return cues.indices.contains(index + 1) ? index + 1 : nil
    }
}

struct AudioStudyStore {
    let root: URL

    init(root: URL = URL.applicationSupportDirectory.appending(path: "SmartRead/AudioStudy", directoryHint: .isDirectory)) {
        self.root = root
    }

    func load() throws -> [AudioStudyEntry] {
        try inventory().entries
    }

    struct Inventory {
        var entries: [AudioStudyEntry] = []
        var unreadable: [URL] = []
    }

    private struct Progress: Codable {
        let position: Double
        let lastOpened: Date
    }

    func inventory() throws -> Inventory {
        var result = Inventory()
        guard FileManager.default.fileExists(atPath: root.path) else { return result }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                 options: .skipsHiddenFiles)
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            do {
                let decoder = JSONDecoder()
                let data = try Data(contentsOf: folder.appending(path: "record.json"))
                var entry = try decoder.decode(AudioStudyEntry.self, from: data)
                guard entry.id == UUID(uuidString: folder.lastPathComponent) else {
                    throw ReaderError.message("音频记录编号不匹配。")
                }
                do {
                    let progress = try decoder.decode(Progress.self, from: Data(contentsOf: folder.appending(path: "progress.json")))
                    entry.position = min(entry.duration, max(0, progress.position))
                    entry.lastOpened = progress.lastOpened
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { /* legacy record */ }
                catch { result.unreadable.append(folder.appending(path: "progress.json")) }
                result.entries.append(entry)
            } catch { result.unreadable.append(folder.appending(path: "record.json")) }
        }
        result.entries.sort { $0.lastOpened > $1.lastOpened }
        return result
    }

    func saveProgress(_ entry: AudioStudyEntry) throws {
        let progress = Progress(position: entry.position, lastOpened: entry.lastOpened)
        try JSONEncoder().encode(progress).write(to: directory(entry.id).appending(path: "progress.json"), options: .atomic)
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func relink(_ source: URL, to entry: AudioStudyEntry) async throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard AudioStudyFormat(url: source) == entry.format else { throw ReaderError.message("请选择相同格式的原音频。") }
        let file = mediaURL(for: entry)
        let staging = directory(entry.id).appending(path: ".repair-\(UUID()).\(entry.format.rawValue)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if let expected = entry.mediaDigest {
            guard try digest(staging) == expected else { throw ReaderError.message("文件内容与原音频不一致。") }
        } else {
            let asset = AVURLAsset(url: staging)
            let duration = try await asset.load(.duration).seconds
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty, abs(duration - entry.duration) < 0.5 else {
                throw ReaderError.message("这个文件的音轨或时长与原记录不符。")
            }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: file)
    }

    func mediaURL(for entry: AudioStudyEntry) -> URL {
        directory(entry.id).appending(path: "media.\(entry.format.rawValue)")
    }

    func add(_ source: URL) async throws -> AudioStudyEntry {
        guard let format = AudioStudyFormat(url: source) else {
            throw ReaderError.message("请选择 MP3 或 MP4 文件。")
        }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ReaderError.message("这个文件里没有可播放的音轨。")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ReaderError.message("无法读取这个文件的时长。")
        }
        try Task.checkCancellation()
        var entry = AudioStudyEntry(id: UUID(), title: source.deletingPathExtension().lastPathComponent,
                                    format: format, duration: duration)
        let folder = directory(entry.id)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try files.copyItem(at: source, to: mediaURL(for: entry))
            try Task.checkCancellation()
            entry.mediaDigest = try digest(mediaURL(for: entry))
            try save(entry)
            return entry
        } catch {
            try? files.removeItem(at: folder)
            throw error
        }
    }

    func save(_ entry: AudioStudyEntry) throws {
        try JSONEncoder().encode(entry).write(to: directory(entry.id).appending(path: "record.json"), options: .atomic)
    }

    private func directory(_ id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}
