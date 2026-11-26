import AVFoundation
import NaturalLanguage
#if compiler(>=6.2)
import Speech
#endif

struct AudioStudyTranscript {
    struct TimedText {
        let range: NSRange
        let start: Double
        let end: Double
    }

    static func cues(in text: String, start: Double, end: Double, timing: [TimedText]) -> [AudioStudyCue] {
        let block = AudioStudyCue(start: start, end: end, text: text)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(.english)
        let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        guard sentences.count > 1 else { return [block] }

        let cues = sentences.compactMap { sentence -> AudioStudyCue? in
            let range = NSRange(sentence, in: text)
            let spans = timing.filter { NSIntersectionRange($0.range, range).length > 0 }
            guard let first = spans.first, let last = spans.last else { return nil }
            return AudioStudyCue(start: first.start, end: last.end, text: String(text[sentence]))
        }
        guard cues.count == sentences.count,
              cues.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }),
              zip(cues, cues.dropFirst()).allSatisfy({ $0.end <= $1.start }) else { return [block] }
        return cues
    }
}

enum AudioStudyTranscriber {
    static var isAvailable: Bool {
#if compiler(>=6.2)
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
#endif
        return false
    }

    static func transcribe(_ source: URL, entry: AudioStudyEntry,
                           status: @escaping @MainActor (String) -> Void) async throws -> [AudioStudyCue] {
#if compiler(>=6.2)
        if #available(macOS 26, *) {
            return try await transcribeLocally(source, entry: entry, status: status)
        }
#endif
        throw ReaderError.message("本机字幕需要支持 Apple 语音转写的 Mac 和 macOS 26 或更新版本。")
    }

#if compiler(>=6.2)
    @available(macOS 26, *)
    private static func transcribeLocally(_ source: URL, entry: AudioStudyEntry,
                                          status: @escaping @MainActor (String) -> Void) async throws -> [AudioStudyCue] {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw ReaderError.message("这台 Mac 当前无法使用本机英语转写。")
        }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let modules = [transcriber]
        if await AssetInventory.status(forModules: modules) != .installed {
            await status("正在准备本机英语识别模型…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw ReaderError.message("无法准备本机英语识别模型。")
            }
        }

        try Task.checkCancellation()
        let extractedAudio = entry.format == .mp4
            ? FileManager.default.temporaryDirectory.appending(path: "SmartRead-\(UUID()).m4a") : nil
        defer {
            if let extractedAudio { try? FileManager.default.removeItem(at: extractedAudio) }
        }
        if let extractedAudio {
            await status("正在读取视频音轨…")
            let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw ReaderError.message("这个 MP4 的音轨无法用于转写。")
            }
            try await exporter.export(to: extractedAudio, as: .m4a)
        }

        try Task.checkCancellation()
        await status("正在本机转写英文字幕…")
        let file = try AVAudioFile(forReading: extractedAudio ?? source)
        let analyzer = SpeechAnalyzer(modules: modules)
        return try await withTaskCancellationHandler {
            let results = Task {
                var cues: [AudioStudyCue] = []
                for try await result in transcriber.results where result.isFinal {
                    try Task.checkCancellation()
                    cues.append(contentsOf: makeCues(from: result))
                }
                return AudioStudyCue.normalized(cues, duration: entry.duration)
            }
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                try Task.checkCancellation()
                return try await results.value
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    @available(macOS 26, *)
    private static func makeCues(from result: SpeechTranscriber.Result) -> [AudioStudyCue] {
        let text = String(result.text.characters)
        var offset = 0
        let timing = result.text.runs.compactMap { run -> AudioStudyTranscript.TimedText? in
            let length = String(result.text[run.range].characters).utf16.count
            let span = NSRange(location: offset, length: length)
            offset += length
            guard let range = run.audioTimeRange else { return nil }
            return .init(range: span, start: range.start.seconds, end: range.end.seconds)
        }
        return AudioStudyTranscript.cues(in: text, start: result.range.start.seconds,
                                         end: result.range.end.seconds, timing: timing)
    }
#endif
}
