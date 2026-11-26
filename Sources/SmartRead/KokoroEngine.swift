import Foundation

actor KokoroEngine {
    private struct Request: Encodable {
        let text: String
        let voice: String
        let speed: Double
    }

    private static let root = URL.applicationSupportDirectory.appending(path: "SmartRead/Kokoro", directoryHint: .isDirectory)
    private static let python = root.appending(path: "env/bin/python")
    static var isInstalled: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: python.path)
            && files.fileExists(atPath: root.appending(path: "kokoro-v1.0.int8.onnx").path)
            && files.fileExists(atPath: root.appending(path: "voices-v1.0.bin").path)
    }

    private let cache = NSCache<NSData, NSData>()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()

    init() {
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 32
    }

    func prepare() throws {
        try Task.checkCancellation()
        if process?.isRunning == true { return }
        reset()
        guard Self.isInstalled, let script = Bundle.module.url(forResource: "KokoroWorker", withExtension: "py") else {
            throw ReaderError.message("Kokoro 语音组件尚未安装。可以先使用 Mac 内建语音。")
        }
        let process = Process()
        let requests = Pipe()
        let responses = Pipe()
        process.executableURL = Self.python
        process.arguments = [script.path, Self.root.path]
        process.standardInput = requests
        process.standardOutput = responses
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = requests.fileHandleForWriting
        output = responses.fileHandleForReading
        _ = fcntl(requests.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            guard try response() == Data("ready".utf8) else { throw disconnected }
        } catch {
            reset()
            throw error
        }
    }

    func audio(for text: String, voice: String, speed: Double = 1) throws -> Data {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Request(text: text, voice: voice, speed: speed))
        if let cached = cache.object(forKey: payload as NSData) { return cached as Data }
        try prepare()
        try Task.checkCancellation()
        do {
            guard let input else { throw disconnected }
            var line = payload
            line.append(10)
            try input.write(contentsOf: line)
            let audio = try response()
            guard audio.starts(with: Data("RIFF".utf8)) else { throw disconnected }
            cache.setObject(audio as NSData, forKey: payload as NSData, cost: audio.count)
            return audio
        } catch {
            reset()
            throw error
        }
    }

    private var disconnected: ReaderError { .message("Kokoro 语音未能播放，请重试或切换到 Mac 内建语音。") }

    private func response() throws -> Data {
        let deadline = ContinuousClock.now + .seconds(30)
        while !pending.contains(10) { try receive(before: deadline) }
        let newline = pending.firstIndex(of: 10)!
        guard let size = Int(String(decoding: pending[..<newline], as: UTF8.self)),
              (1...16_000_000).contains(size) else { throw disconnected }
        pending.removeFirst(pending.distance(from: pending.startIndex, to: newline) + 1)
        while pending.count < size { try receive(before: deadline) }
        let data = Data(pending.prefix(size))
        pending.removeFirst(size)
        if data.starts(with: Data("error:".utf8)) { throw disconnected }
        return data
    }

    private func receive(before deadline: ContinuousClock.Instant) throws {
        guard let output else { throw disconnected }
        var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let result = poll(&descriptor, 1, 50)
            if result == 0 || (result < 0 && errno == EINTR) { continue }
            guard result > 0 else { throw disconnected }
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw disconnected }
            pending.append(chunk)
            return
        }
        throw ReaderError.message("Kokoro 语音生成超时。可以重试或使用 Mac 内建语音。")
    }

    private func reset() {
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        try? output?.close()
        process = nil
        input = nil
        output = nil
        pending.removeAll()
    }
}
