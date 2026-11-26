import Foundation

struct EmbeddedSubtitleTrack: Identifiable, Equatable, Hashable, Sendable {
    let id: Int
    let languageCode: String?
    let title: String?
    let codec: String
    let isDefault: Bool
    let isForced: Bool
    let isTextBased: Bool

    var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty {
            parts.append(title)
        } else if let languageName {
            parts.append(languageName)
        } else {
            parts.append("未标注语言")
        }
        parts.append("轨道 \(id)")
        if isDefault {
            parts.append("默认")
        }
        if !isTextBased {
            parts.append("图像字幕")
        }
        return parts.joined(separator: " · ")
    }

    var normalizedLanguageCode: String? {
        languageCode?.lowercased()
    }

    private var languageName: String? {
        guard let languageCode, !languageCode.isEmpty else { return nil }
        let normalized = languageCode.lowercased()
        let knownNames = [
            "eng": "English",
            "en": "English",
            "zho": "中文",
            "chi": "中文",
            "zh": "中文",
            "chs": "简体中文",
            "cht": "繁體中文",
            "jpn": "日本語",
            "ja": "日本語",
            "kor": "한국어",
            "ko": "한국어"
        ]
        return knownNames[normalized] ?? languageCode.uppercased()
    }
}

protocol EmbeddedSubtitleServiceProtocol: Sendable {
    func discoverTracks(in sourceURL: URL) async throws -> [EmbeddedSubtitleTrack]
    func extract(
        track: EmbeddedSubtitleTrack,
        from sourceURL: URL
    ) async throws -> Data
}

enum EmbeddedSubtitleError: LocalizedError, Equatable {
    case ffmpegUnavailable
    case probeFailed(String)
    case imageSubtitleUnsupported
    case extractionFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .ffmpegUnavailable:
            return "读取内嵌字幕需要本机 FFmpeg。"
        case let .probeFailed(message):
            return "无法读取视频轨道：\(message)"
        case .imageSubtitleUnsupported:
            return "该轨道是图像字幕，首版无法转换为可点击文本。"
        case let .extractionFailed(message):
            return "内嵌字幕提取失败：\(message)"
        case .emptyOutput:
            return "这个字幕轨道没有可用文本。"
        }
    }
}

actor EmbeddedSubtitleService: EmbeddedSubtitleServiceProtocol {
    private let fileManager: FileManager
    private let ffmpegURLOverride: URL?
    private let cacheDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        ffmpegURL: URL? = nil,
        cacheDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.ffmpegURLOverride = ffmpegURL
        self.cacheDirectoryOverride = cacheDirectory
    }

    func discoverTracks(in sourceURL: URL) async throws -> [EmbeddedSubtitleTrack] {
        let ffmpegURL = try locateFFmpeg()
        let result = try await runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-nostdin",
                "-i", sourceURL.standardizedFileURL.path
            ],
            acceptsNonZeroExit: true
        )
        return Self.parseTracks(from: result.standardError)
    }

    func extract(
        track: EmbeddedSubtitleTrack,
        from sourceURL: URL
    ) async throws -> Data {
        guard track.isTextBased else {
            throw EmbeddedSubtitleError.imageSubtitleUnsupported
        }

        let standardizedSource = sourceURL.standardizedFileURL
        let ffmpegURL = try locateFFmpeg()
        let cacheDirectory = try cacheDirectory()
        let fingerprint = try fingerprint(for: standardizedSource)
        let outputURL = cacheDirectory.appending(
            path: "\(fingerprint)-stream-\(track.id).srt"
        )

        if isUsableFile(at: outputURL) {
            return try Data(contentsOf: outputURL)
        }

        let partialURL = cacheDirectory.appending(
            path: "\(fingerprint)-stream-\(track.id)-\(UUID().uuidString).partial.srt"
        )
        defer {
            try? fileManager.removeItem(at: partialURL)
        }

        _ = try await runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-y",
                "-i", standardizedSource.path,
                "-map", "0:\(track.id)",
                "-vn",
                "-an",
                "-c:s", "srt",
                partialURL.path
            ],
            acceptsNonZeroExit: false
        )

        guard isUsableFile(at: partialURL) else {
            throw EmbeddedSubtitleError.emptyOutput
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: partialURL, to: outputURL)
        return try Data(contentsOf: outputURL)
    }

    static func parseTracks(from probeOutput: String) -> [EmbeddedSubtitleTrack] {
        let pattern = #"Stream #\d+:(\d+)(?:\[[^\]]+\])?(?:\(([^)]+)\))?: Subtitle: ([^,\s]+)(.*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let textCodecs: Set<String> = [
            "ass",
            "eia_608",
            "eia_708",
            "microdvd",
            "mov_text",
            "mpl2",
            "realtext",
            "sami",
            "srt",
            "ssa",
            "stl",
            "subrip",
            "subviewer",
            "subviewer1",
            "text",
            "vplayer",
            "webvtt"
        ]

        var tracks: [EmbeddedSubtitleTrack] = []
        var currentTrackArrayIndex: Int?
        for line in probeOutput.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range) else {
                if line.contains("Stream #") {
                    currentTrackArrayIndex = nil
                } else if let currentTrackArrayIndex,
                          let title = metadataTitle(from: line) {
                    let existing = tracks[currentTrackArrayIndex]
                    tracks[currentTrackArrayIndex] = EmbeddedSubtitleTrack(
                        id: existing.id,
                        languageCode: existing.languageCode,
                        title: title,
                        codec: existing.codec,
                        isDefault: existing.isDefault,
                        isForced: existing.isForced
                            || title.localizedCaseInsensitiveContains("forced")
                            || title.contains("强制"),
                        isTextBased: existing.isTextBased
                    )
                }
                continue
            }
            guard let indexRange = Range(match.range(at: 1), in: line),
                  let streamIndex = Int(line[indexRange]),
                  let codecRange = Range(match.range(at: 3), in: line) else {
                currentTrackArrayIndex = nil
                continue
            }

            let languageCode: String?
            if match.range(at: 2).location != NSNotFound,
               let languageRange = Range(match.range(at: 2), in: line) {
                languageCode = String(line[languageRange])
            } else {
                languageCode = nil
            }

            let codec = String(line[codecRange]).lowercased()
            let flags: String
            if match.range(at: 4).location != NSNotFound,
               let flagsRange = Range(match.range(at: 4), in: line) {
                flags = String(line[flagsRange]).lowercased()
            } else {
                flags = ""
            }

            tracks.append(
                EmbeddedSubtitleTrack(
                    id: streamIndex,
                    languageCode: languageCode,
                    title: nil,
                    codec: codec,
                    isDefault: flags.contains("(default)"),
                    isForced: flags.contains("(forced)"),
                    isTextBased: textCodecs.contains(codec)
                )
            )
            currentTrackArrayIndex = tracks.indices.last
        }
        return tracks
    }

    private static func metadataTitle(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("title"),
              let separator = trimmed.firstIndex(of: ":") else {
            return nil
        }
        let title = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private func locateFFmpeg() throws -> URL {
        if let ffmpegURLOverride,
           fileManager.isExecutableFile(atPath: ffmpegURLOverride.path) {
            return ffmpegURLOverride
        }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            homeDirectory.appending(path: ".local/bin/ffmpeg"),
            homeDirectory.appending(path: "bin/ffmpeg")
        ].compactMap { $0 }

        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw EmbeddedSubtitleError.ffmpegUnavailable
        }
        return executable
    }

    private func cacheDirectory() throws -> URL {
        let directory: URL
        if let cacheDirectoryOverride {
            directory = cacheDirectoryOverride
        } else {
            directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "SmartRead/VideoStudy", directoryHint: .isDirectory)
                .appending(path: "EmbeddedSubtitles", directoryHint: .isDirectory)
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func fingerprint(for url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? NSNumber
        let modifiedAt = attributes[.modificationDate] as? Date
        let input = [
            url.path,
            fileSize?.stringValue ?? "0",
            String(modifiedAt?.timeIntervalSince1970 ?? 0)
        ].joined(separator: "|")

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func isUsableFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        acceptsNonZeroExit: Bool
    ) async throws -> (standardError: String, terminationStatus: Int32) {
        let process = Process()
        let processBox = EmbeddedSubtitleProcessBox(process)
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finishedProcess in
                    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(decoding: errorData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if finishedProcess.terminationStatus == 0 || acceptsNonZeroExit {
                        continuation.resume(
                            returning: (
                                standardError: errorMessage,
                                terminationStatus: finishedProcess.terminationStatus
                            )
                        )
                    } else if finishedProcess.terminationReason == .uncaughtSignal,
                              finishedProcess.terminationStatus == SIGTERM {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            throwing: EmbeddedSubtitleError.extractionFailed(
                                errorMessage.isEmpty
                                    ? "FFmpeg 退出码 \(finishedProcess.terminationStatus)"
                                    : errorMessage
                            )
                        )
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: EmbeddedSubtitleError.probeFailed(
                            error.localizedDescription
                        )
                    )
                }
            }
        } onCancel: {
            if processBox.process.isRunning {
                processBox.process.terminate()
            }
        }
    }
}

private final class EmbeddedSubtitleProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
