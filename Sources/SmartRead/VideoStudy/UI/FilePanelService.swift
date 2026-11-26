import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePanelService {
    static func chooseVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "打开视频"
        panel.prompt = "打开"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var contentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        if let m4v = UTType(filenameExtension: "m4v") {
            contentTypes.append(m4v)
        }
        if let matroska = UTType(filenameExtension: "mkv") {
            contentTypes.append(matroska)
        }
        panel.allowedContentTypes = contentTypes
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSubtitle(languageName: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "加载\(languageName)字幕"
        panel.prompt = "加载"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let srt = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srt]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseDirectory(
        title: String,
        prompt: String,
        initialDirectory: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }
}
