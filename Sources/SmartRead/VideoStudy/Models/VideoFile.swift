import AppKit

enum VideoFile {
    static let supportedExtensions: Set<String> = ["mp4", "mov", "mkv", "m4v"]

    static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL,
              supportedExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.first(where: isSupported)
    }
}
