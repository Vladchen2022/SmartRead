import CryptoKit
import Foundation

/// Only successfully decoded, locally checked explanations enter this cache.
/// Keys include model, local endpoint, request context and validation version.
actor AIResponseCache {
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "SmartRead/VideoStudy/LocalAI-v4", directoryHint: .isDirectory)
    }
    private let directory: URL?
    private var memory: [String: Data] = [:]
    init(directory: URL?) { self.directory = directory }

    nonisolated static func key(kind: String, endpoint: String, model: String, parts: [String]) -> String {
        let values = [AIValidationPolicy.version, kind, endpoint, model] + parts
        return SHA256.hash(data: Data(values.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func read(_ key: String) -> Data? {
        if let value = memory[key] { return value }
        guard let directory,
              let value = try? Data(contentsOf: directory.appending(path: "aevp-ai-\(key).json")),
              value.count < 128_000 else { return nil }
        return value
    }
    func store(_ value: Data, key: String) {
        guard value.count < 128_000 else { return }
        if memory.count >= 128 { memory.removeAll(keepingCapacity: true) }
        memory[key] = value
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try value.write(to: directory.appending(path: "aevp-ai-\(key).json"), options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                .filter { $0.lastPathComponent.hasPrefix("aevp-ai-") && $0.pathExtension == "json" }
            if files.count > 256 {
                let sorted = files.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                for url in sorted.prefix(files.count - 256) { try? FileManager.default.removeItem(at: url) }
            }
        } catch { /* A cache failure must never discard a checked answer. */ }
    }
}
