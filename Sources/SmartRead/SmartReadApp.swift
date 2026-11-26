import SwiftUI

enum ReaderMode: String, CaseIterable, Codable {
    case text, audio, video

    var title: String {
        switch self {
        case .text: "文本阅读"
        case .audio: "音频精听"
        case .video: "视频精学"
        }
    }

    var importTitle: String {
        switch self {
        case .text: "导入文章"
        case .audio: "导入音频"
        case .video: "导入视频"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.book.closed"
        case .audio: "waveform"
        case .video: "play.rectangle"
        }
    }

    var historySheet: ReaderSheet {
        switch self {
        case .text: .history
        case .audio: .audioHistory
        case .video: .videoHistory
        }
    }
}

@main
struct SmartReadApp: App {
    @NSApplicationDelegateAdaptor private var application: SmartReadApplication
    @State private var mode = ReaderMode.text
    @State private var sheet: ReaderSheet?
    @State private var choosesAudioFile = false
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReadingFontSize.defaultValue

    private var reader: ReaderModel { application.reader }
    private var speech: ReaderSpeech { application.speech }
    private var audioStudy: AudioStudyModel { application.audioStudy }

    var body: some Scene {
        Window("SmartRead", id: "reader") {
            ReaderWindow(reader: reader, speech: speech, audio: audioStudy, video: application.videoStudy,
                         mode: $mode, sheet: $sheet,
                         fontSize: $fontSize, choosesAudioFile: $choosesAudioFile, openPDF: openPDF)
                .frame(minWidth: 760, minHeight: 560)
                .onAppear {
                    application.importFile = { [reader, audioStudy] url in
                        if !(mode == .audio && AudioStudyFormat(url: url) != nil), VideoFile.isSupported(url) {
                            mode = .video
                            application.videoStudy.openVideo(url)
                            return
                        }
                        if AudioStudyFormat(url: url) != nil {
                            mode = .audio
                            audioStudy.restore()
                            audioStudy.importMedia(url)
                            return
                        }
                        mode = .text
                        if url.pathExtension.lowercased() == "pdf" {
                            openPDF(url)
                            return
                        }
                        do {
                            try reader.importFile(url)
                        } catch {
                            reader.notice = "无法导入 \(url.lastPathComponent)。\n\(error.localizedDescription)"
                        }
                    }
                }
        }
        .defaultSize(width: 1170, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button(mode.importTitle + "…") {
                    switch mode {
                    case .text: sheet = .importArticle
                    case .audio: choosesAudioFile = true
                    case .video:
                        if let file = FilePanelService.chooseVideo() { application.videoStudy.openVideo(file) }
                    }
                }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(mode == .audio && audioStudy.isImporting)
                Button("历史记录…") { sheet = mode.historySheet }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandMenu("阅读") {
                Button("翻译选区") { reader.lookUp(.translation) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(mode != .text || !reader.hasEnglishSelection || sheet != nil)
                Button("语法解析") { reader.lookUp(.analysis) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(mode != .text || !reader.hasEnglishSelection || sheet != nil)
                Divider()
                Button("放大字号") { fontSize = min(ReadingFontSize.range.upperBound, fontSize + 2) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小字号") { fontSize = max(ReadingFontSize.range.lowerBound, fontSize - 2) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("恢复默认字号") { fontSize = ReadingFontSize.defaultValue }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            ReaderSettings(reader: reader, speech: speech, video: application.videoStudy)
                .tint(ReaderPalette.primaryButton)
        }
    }

    private func openPDF(_ url: URL) {
        let readerMode = $mode
        let readerSheet = $sheet
        application.openPDF(url, onBack: {
            readerMode.wrappedValue = .text
            readerSheet.wrappedValue = .importArticle
        }, onImport: {
            readerMode.wrappedValue = .text
        })
    }
}

@MainActor
final class SmartReadApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // The app and Settings scenes share the same session for the life of the process.
    let reader = ReaderModel(loadsLearningRecordsInBackground: true)
    let speech = ReaderSpeech()
    let audioStudy = AudioStudyModel()
    lazy var videoStudy = VideoStudyModel(modelSettings: { [reader] in
        let preferred = reader.preferredModel
        return (reader.endpoint, preferred.isEmpty ? reader.models.first ?? "" : preferred)
    })

    private var pendingFiles: [URL] = []
    private var pdfWindows: [URL: NSWindowController] = [:]

    func applicationWillFinishLaunching(_ notification: Notification) {
        ReaderTheme.saved().apply()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        reader.weeklyFavorites.resume()
    }
    var importFile: ((URL) -> Void)? {
        didSet {
            guard let importFile else { return }
            let files = pendingFiles
            pendingFiles.removeAll()
            files.forEach(importFile)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        if let importFile { files.forEach(importFile) }
        else { pendingFiles.append(contentsOf: files) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        videoStudy.prepareForTermination()
    }

    func openPDF(_ url: URL, onBack: @escaping () -> Void, onImport: @escaping () -> Void) {
        let key = url.standardizedFileURL
        if let existing = pdfWindows[key] {
            existing.showWindow(nil)
            return
        }

        let readerWindow = NSApp.mainWindow ?? NSApp.keyWindow
        let screen = readerWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let content = NSRect(x: 0, y: 0, width: min(1360, screen.width * 0.92),
                             height: min(940, screen.height * 0.88))
        let window = NSWindow(contentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "导入 PDF"
        window.identifier = NSUserInterfaceItemIdentifier("pdfImport")
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self

        let controller = NSWindowController(window: window)
        let close: () -> Void = { [weak controller] in controller?.close() }
        let host = NSHostingController(rootView: PDFImportView(url: url, reader: reader, close: close, back: { [weak readerWindow] in
            close()
            readerWindow?.makeKeyAndOrderFront(nil)
            onBack()
        }, imported: { [weak readerWindow] in
            close()
            onImport()
            readerWindow?.makeKeyAndOrderFront(nil)
        }))
        host.sizingOptions = .minSize
        window.contentViewController = host
        window.setContentSize(content.size)
        window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
        pdfWindows[key] = controller
        controller.showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = pdfWindows.first(where: { $0.value.window === window })?.key else { return }
        pdfWindows.removeValue(forKey: key)
    }
}

enum ReadingFontSize {
    static let range = 16.0...72.0
    static let defaultValue = 24.0
}

enum ReaderSheet: String, Identifiable {
    case importArticle, history, audioHistory, videoHistory, readingFeedback, favorites
    var id: String { rawValue }
}

struct ReaderWindow: View {
    let reader: ReaderModel
    let speech: ReaderSpeech
    let audio: AudioStudyModel
    let video: VideoStudyModel
    @Binding var mode: ReaderMode
    @Binding var sheet: ReaderSheet?
    @Binding var fontSize: Double
    @Binding var choosesAudioFile: Bool
    let openPDF: (URL) -> Void
    private var preferences = ReaderPreferences()
    @Environment(\.openURL) private var openURL
    @AppStorage("audioStudyShowsSubtitles") private var showsSubtitles = true
    @GestureState private var dividerOffset: CGFloat = 0
    @State private var copied = false
    @State private var showsStudyTools = false
    @State private var showsModeMenu = false
    @State private var showsDisplayOptions = false
    @State private var editingCue: AudioStudyCue?
    @State private var pendingPDF: URL?
    @State private var pdfBookPanel: PDFBookPanel?
    @State private var dropTarget = false
    @State private var subtitleAssistant = AudioSubtitleAssistant()

    private var interfaceScale: CGFloat { preferences.interfaceSize.scale }
    private static let brandIcon: NSImage? = {
        let url = Bundle.main.url(forResource: "SmartRead", withExtension: "icns")
            ?? Bundle.module.url(forResource: "SmartRead", withExtension: "icns")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()
    private var inAudioMode: Bool { mode == .audio }
    private var inVideoMode: Bool { mode == .video }

    var body: some View {
        let article = reader.article
        let articleVersion = reader.articleVersion
        return GeometryReader { geometry in
            let width = geometry.size.width
            let layout = paneLayout(windowWidth: width, inspectorDelta: -dividerOffset)
            VStack(spacing: 0) {
                toolbar(articleWidthPercent: layout.articleWidthPercent, windowWidth: width)
                Rectangle().fill(ReaderPalette.rule).frame(height: 1)
                columns(layout: layout, windowWidth: width, article: article, articleVersion: articleVersion)
                switch mode {
                case .audio:
                    if audio.entry != nil { AudioPlayerBar(model: audio) }
                case .text:
                    if speech.current != nil { SpeechPlayerBar(speech: speech) }
                case .video:
                    VideoPlayerBar(model: video, controller: video.playerController)
                }
            }
        }
        .foregroundStyle(ReaderPalette.ink)
        .background(ReaderPalette.paper)
        .tint(ReaderPalette.primaryButton)
        .task {
            speech.warmUp()
            await reader.connect()
        }
        .onChange(of: articleVersion) { speech.stop() }
        .onChange(of: audio.entry?.id) { subtitleAssistant.clear() }
        .onChange(of: showsSubtitles) {
            if !showsSubtitles { subtitleAssistant.clear() }
        }
        .onChange(of: mode) { previous, next in
            showsStudyTools = false
            switch previous {
            case .text: speech.pause()
            case .audio: audio.pause(); dropTarget = false
            case .video: video.pauseForModeSwitch()
            }
            if next == .audio { audio.restore() }
        }
        .onDisappear {
            speech.stop()
            if inAudioMode { audio.pause() }
            if inVideoMode { video.pauseForModeSwitch() }
        }
        .sheet(item: $sheet, onDismiss: {
            guard let url = pendingPDF else { return }
            pendingPDF = nil
            openPDF(url)
        }) { choice in
            switch choice {
            case .importArticle: ImportSheet(reader: reader) { pendingPDF = $0 }
            case .history: HistorySheet(reader: reader)
            case .audioHistory: AudioHistorySheet(model: audio)
            case .videoHistory: VideoHistorySheet(model: video)
            case .readingFeedback: ReadingFeedbackSheet(reader: reader)
            case .favorites: ArticleFavoritesSheet(reader: reader)
            }
        }
        .sheet(item: $editingCue) { cue in
            AudioCueEditor(cue: cue) { updated in
                try audio.editCue(updated)
                if cue.text != updated.text { subtitleAssistant.clear() }
            }
        }
        .sheet(item: $pdfBookPanel) { panel in
            if let page = reader.article.pdfPage {
                switch panel {
                case .original:
                    PDFBookOriginalPage(reader: reader, location: page, pageIndex: reader.currentPDFSourcePage ?? page.index)
                case .chapters:
                    PDFChapterBrowser(reader: reader, location: page)
                case .translation:
                    if let chapter = page.chapter { PDFChapterTranslation(reading: chapter) }
                }
            }
        }
        .fileImporter(isPresented: $choosesAudioFile, allowedContentTypes: AudioStudyFormat.contentTypes) { result in
            switch result {
            case .success(let url): audio.importMedia(url)
            case .failure(let error): audio.issue = error.localizedDescription
            }
        }
        .alert("文章", isPresented: Binding(
            get: { mode == .text && reader.notice != nil },
            set: { if !$0 { reader.notice = nil } }
        )) {
            Button("好") { reader.notice = nil }
        } message: {
            Text(reader.notice ?? "")
        }
        .alert("音频精听", isPresented: Binding(
            get: { inAudioMode && audio.issue != nil },
            set: { if !$0 { audio.issue = nil } }
        )) {
            Button("好") { audio.issue = nil }
        } message: {
            Text(audio.issue ?? "")
        }
        .environment(\.readerInterfaceScale, interfaceScale)
    }

    private func paneLayout(windowWidth: CGFloat, inspectorDelta: CGFloat = 0) -> ReaderPaneLayout {
        ReaderPaneLayout(windowWidth: windowWidth, inspectorFraction: preferences.inspectorFraction,
                         bodyWidth: preferences.bodyWidth, inspectorDelta: inspectorDelta)
    }

    private func columns(layout: ReaderPaneLayout, windowWidth: CGFloat, article: Article, articleVersion: UUID) -> some View {
        HStack(spacing: 0) {
            ZStack {
                articleColumn(article, version: articleVersion, contentWidth: layout.articleContentWidth)
                    .opacity(mode == .text ? 1 : 0)
                    .disabled(mode != .text)
                    .allowsHitTesting(mode == .text)
                    .accessibilityHidden(mode != .text)
                if inAudioMode {
                    AudioStudyContent(model: audio, fontSize: fontSize, showsSubtitles: showsSubtitles,
                                      maskOpacity: preferences.listeningMaskOpacity,
                                      highlightsSentence: preferences.highlightsSpokenSentence,
                                      selection: subtitleAssistant.selection, lookUp: lookUpSubtitle, edit: editCue)
                        .frame(width: layout.articleContentWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if dropTarget {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(ReaderPalette.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                                    .padding(6)
                                    .allowsHitTesting(false)
                            }
                        }
                        .dropDestination(for: URL.self) { files, _ in
                            guard !audio.isImporting,
                                  let file = files.first(where: { AudioStudyFormat(url: $0) != nil }) else { return false }
                            audio.importMedia(file)
                            return true
                        } isTargeted: { dropTarget = $0 }
                }
                if inVideoMode {
                    VideoStudyContent(model: video, fontSize: fontSize, subtitleWidth: layout.articleContentWidth,
                                      chooseVideo: chooseVideo, openHistory: { sheet = .videoHistory })
                }
            }
            .frame(width: layout.articleWidth)

            ReaderDivider(isResizing: dividerOffset != 0)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($dividerOffset) { drag, offset, _ in offset = drag.translation.width }
                        .onEnded { drag in
                            preferences.inspectorFraction = paneLayout(windowWidth: windowWidth,
                                                                       inspectorDelta: -drag.translation.width).inspectorFraction
                        }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(inVideoMode ? "右侧视频助手宽度" : inAudioMode ? "右侧音频助手宽度" : "右侧阅读助手宽度")
                .accessibilityValue("\(Int(layout.inspectorWidth)) 磅")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        preferences.inspectorFraction = paneLayout(windowWidth: windowWidth, inspectorDelta: 40).inspectorFraction
                    case .decrement:
                        preferences.inspectorFraction = paneLayout(windowWidth: windowWidth, inspectorDelta: -40).inspectorFraction
                    @unknown default: break
                    }
                }

            ZStack {
                inspector
                    .opacity(mode == .text ? 1 : 0)
                    .disabled(mode != .text)
                    .allowsHitTesting(mode == .text)
                    .accessibilityHidden(mode != .text)
                if inAudioMode {
                    AudioStudyInspector(model: audio, assistant: subtitleAssistant, reader: reader,
                                        fontSize: fontSize, showsSubtitles: $showsSubtitles, edit: editCue,
                                        locateQuestionSource: locateQuestionSource)
                }
                if inVideoMode {
                    VideoStudyInspector(model: video, reader: reader, locateQuestionSource: locateQuestionSource)
                }
            }
            .frame(width: layout.inspectorWidth)
        }
        .frame(maxHeight: .infinity)
    }

    private func toolbar(articleWidthPercent: Int, windowWidth: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12 * interfaceScale) {
                toolbarPrimary
                Spacer(minLength: 8)
                displayControls(articleWidthPercent: articleWidthPercent)
                modeButton(showTitle: true)
                settingsLink(showStatus: true)
            }
            HStack(spacing: 10 * interfaceScale) {
                toolbarPrimary
                Spacer(minLength: 6)
                displayControls(articleWidthPercent: articleWidthPercent)
                modeButton(showTitle: false)
                settingsLink(showStatus: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10 * interfaceScale) {
                    toolbarPrimary
                    Spacer(minLength: 0)
                    modeButton(showTitle: windowWidth >= 900)
                    settingsLink(showStatus: false)
                }
                displayControls(articleWidthPercent: articleWidthPercent)
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 22)
        .padding(.vertical, 8)
        .background(ReaderPalette.chrome)
    }

    private func modeButton(showTitle: Bool) -> some View {
        Button { showsModeMenu.toggle() } label: {
            HStack(spacing: 8 * interfaceScale) {
                if showTitle {
                    Label(mode.title, systemImage: mode.symbol)
                } else {
                    Image(systemName: mode.symbol)
                }
                Image(systemName: "chevron.down").imageScale(.small)
            }
        }
        .buttonStyle(ReaderButtonStyle(prominent: showsModeMenu, compact: true, scale: 1.45))
        .fixedSize()
        .accessibilityLabel("学习模式")
        .accessibilityValue(mode.title)
        .accessibilityIdentifier("switchReaderMode")
        .help("切换文本阅读、音频精听或视频精学")
        .popover(isPresented: $showsModeMenu, arrowEdge: .bottom) {
            VStack(spacing: 6 * interfaceScale) {
                ForEach(ReaderMode.allCases, id: \.self) { choice in
                    Button { showsModeMenu = false; mode = choice } label: {
                        HStack {
                            Label(choice.title, systemImage: choice.symbol)
                            Spacer(minLength: 10)
                            if mode == choice { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .buttonStyle(ReaderButtonStyle(prominent: mode == choice, compact: true, scale: 1.4))
                    .accessibilityIdentifier("readerMode-\(choice)")
                    .accessibilityAddTraits(mode == choice ? .isSelected : [])
                }
            }
            .frame(width: 160 * interfaceScale)
            .padding(10 * interfaceScale)
            .background(ReaderPalette.chrome)
            .environment(\.readerInterfaceScale, interfaceScale)
        }
    }

    private func chooseVideo() {
        if let file = FilePanelService.chooseVideo() { video.openVideo(file) }
    }

    private var toolbarPrimary: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                if let icon = Self.brandIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30 * interfaceScale, height: 30 * interfaceScale)
                        .accessibilityHidden(true)
                }
                Text("SmartRead")
                    .font(.system(size: 18 * interfaceScale, weight: .semibold, design: .serif))
                    .lineLimit(1)
            }
            .fixedSize()

            Button {
                switch mode {
                case .text: sheet = .importArticle
                case .audio: choosesAudioFile = true
                case .video: chooseVideo()
                }
            } label: {
                Label(mode.importTitle, systemImage: "plus")
            }
            .buttonStyle(ReaderButtonStyle(prominent: true, compact: true, scale: 1.6, primary: true))
            .fixedSize()
            .disabled(inAudioMode && audio.isImporting)
            .accessibilityIdentifier(inVideoMode ? "importVideo" : inAudioMode ? "importAudio" : "importArticle")
            .help(mode.importTitle + "（⌘I）")

            Button { sheet = mode.historySheet } label: {
                Label("历史记录", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.6))
            .fixedSize()
            .accessibilityIdentifier(inVideoMode ? "videoHistory" : inAudioMode ? "audioHistory" : "articleHistory")
            .help("历史记录（⇧⌘H）")
        }
    }

    private func displayControls(articleWidthPercent: Int) -> some View {
        HStack(spacing: 10 * interfaceScale) {
            if preferences.showsToolbarSliders { fontSlider }
            Button { showsDisplayOptions.toggle() } label: {
                Label("显示", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(ReaderButtonStyle(prominent: showsDisplayOptions, compact: true, scale: 1.25))
            .accessibilityIdentifier("displayOptions")
            .help("调整字号、内容宽度和听读遮罩")
            .popover(isPresented: $showsDisplayOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if !preferences.showsToolbarSliders { fontSlider }
                    let widthTitle = mode == .text ? "正文宽度" : "字幕宽度"
                    LargeReaderSlider(title: widthTitle, accessibilityTitle: widthTitle, valueText: "\(articleWidthPercent)%",
                                      value: preferences.$bodyWidth, range: 0...1, step: 0.01)
                    if !inVideoMode {
                        LargeReaderSlider(title: "遮罩", accessibilityTitle: "听读遮罩深浅",
                                          valueText: "\(Int((preferences.listeningMaskOpacity * 100).rounded()))%",
                                          value: preferences.$listeningMaskOpacity, range: ReaderPreferences.maskRange, step: 0.05)
                            .help("调到 0% 可关闭遮罩")
                    }
                }
                .padding(14)
                .background(ReaderPalette.chrome)
                .environment(\.readerInterfaceScale, interfaceScale)
            }
        }
        .fixedSize()
    }

    private var fontSlider: some View {
        LargeReaderSlider(title: "字号", accessibilityTitle: mode == .text ? "阅读字号" : "字幕字号",
                          valueText: "\(Int(fontSize))", value: $fontSize, range: ReadingFontSize.range, step: 1)
    }

    private func editCue(_ cue: AudioStudyCue) {
        audio.pause()
        editingCue = cue
    }

    private func lookUpSubtitle(_ cueID: UUID, _ target: SubtitleWord) {
        guard inAudioMode, showsSubtitles, let entry = audio.entry,
              let selection = AudioSubtitleSelection(entry: entry, cueID: cueID, target: target) else { return }
        if audio.isPlaying { audio.pause() }
        audio.selectQuestionReference(selection)
        subtitleAssistant.show(.word, for: selection, using: reader)
    }

    private func settingsLink(showStatus: Bool) -> some View {
        HStack(spacing: 8) {
            if showStatus {
                Label {
                    Text(connectionLabel).font(.system(size: max(11, 14 * interfaceScale), weight: .medium))
                } icon: {
                    Circle().fill(connectionColor).frame(width: 7, height: 7)
                }
                .foregroundStyle(ReaderPalette.muted)
            }
            SettingsLink {
                Label("设置", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.6))
            .accessibilityLabel("设置")
            .accessibilityIdentifier("openReaderSettings")
            .help("SmartRead 设置（⌘,）")
        }
        .fixedSize()
    }

    private func articleColumn(_ article: Article, version: UUID, contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    if let page = article.pdfPage {
                        Label(page.usedOCR ? "PDF 电子书 · 本机 OCR" : "PDF 电子书", systemImage: "book.closed")
                        if page.chapter != nil, let source = reader.currentPDFSourcePage {
                            Text("PDF 第 \(source + 1) 页")
                                .accessibilityIdentifier("pdfChapterSourcePage")
                        }
                    } else if let source = article.sourceURL {
                        Button {
                            openURL(source)
                        } label: {
                            Label(source.host ?? "打开原文", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ReaderPalette.accent)
                        .help("在浏览器打开原文")
                    } else {
                        Label("本地文章", systemImage: "doc.text")
                    }
                    if let byline = article.byline, !byline.isEmpty {
                        Text("·")
                        Text(byline).lineLimit(1)
                    }
                    Spacer()
                    if reader.inlineTranslation != nil {
                        Button("收起译文") { reader.closeInlineTranslation() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("closeInlineTranslation")
                    }
                    if reader.hasEnglishReadingText {
                        SpeechMenu(speech: speech, selection: reader.hasEnglishSelection ? reader.selection : nil,
                                   playArticle: { playArticle(fromHere: $0) }, playSelection: playSelection)
                    }
                    Text("\(article.wordCount.formatted()) 词")
                        .font(.system(size: 15 * interfaceScale, weight: .medium))
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(.system(size: max(11, 12 * interfaceScale), weight: .medium))
                .foregroundStyle(ReaderPalette.muted)

                Text(article.title.isEmpty ? "英文文章" : article.title)
                    .font(.system(size: min(42, max(32, fontSize + 8)), weight: .regular, design: .serif))
                    .tracking(-0.65)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .help(article.title)

                if let page = article.pdfPage {
                    PDFBookNavigation(reader: reader, location: page) { pdfBookPanel = $0 }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        articleRecordButtons
                        if reader.hasEnglishReadingText { sentenceModeButton }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        articleRecordButtons
                        if reader.hasEnglishReadingText { sentenceModeButton }
                    }
                }

                Rectangle().fill(ReaderPalette.rule).frame(height: 1)
            }
            .padding(.top, 31)
            .padding(.horizontal, 4)

            if article.body.isEmpty, let page = article.pdfPage {
                ContentUnavailableView(
                    page.englishOnly ? "本页没有英文正文" : "本页没有识别出文字",
                    systemImage: "doc.text",
                    description: Text(page.englishOnly ? "点击「只读英文」切回全部内容，或查看原页。" : "可以查看 PDF 原页，或翻到下一页。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReaderTextView(
                    bodyText: article.body,
                    version: version,
                    fontSize: fontSize,
                    marks: reader.marks,
                    inlineTranslation: reader.inlineTranslation,
                    jump: reader.jump,
                    listeningFocus: speech.focusRequest.map { request in
                        ListeningFocus(request: request, paragraph: reader.listeningParagraph(for: request.range))
                    },
                    maskOpacity: preferences.listeningMaskOpacity,
                    highlightsSpeech: preferences.highlightsSpokenSentence,
                    interfaceScale: interfaceScale,
                    onListeningFocusArrived: speech.focusArrived,
                    wordAction: reader.study == nil ? reader.focusedWord.map {
                        SelectionActions.WordAction(excerpt: $0, study: reader.referenceWord == nil ? .phrase : .reference)
                    } : nil,
                    onSelection: { reader.selection = $0 },
                    onUserSelection: reader.selectQuestionReference,
                    allowsLanguageActions: reader.canAssist,
                    onUserPhraseSelection: { selected in
                        guard let phrase = reader.shortPhrase(in: selected.range) else { return }
                        speech.pause()
                        reader.lookUp(.word, excerpt: phrase)
                    },
                    onTranslateSelection: { excerpt in
                        speech.pause()
                        reader.lookUp(.translation, excerpt: excerpt)
                    },
                    onTextClick: { position in
                        let queried = reader.clickText(at: position, wholeSentence: preferences.clickWholeSentence)
                        if queried { speech.pause() }
                        return queried
                    },
                    onReadingPosition: { position, version, saveForResume in
                        if mode == .text, reader.articleVersion == version {
                            reader.didScroll(to: position, saveForResume: saveForResume)
                        }
                    },
                    onCloseInline: { reader.closeInlineTranslation() },
                    onTranslateSentence: { excerpt in
                        speech.pause()
                        reader.translateSentence(containing: excerpt)
                    },
                    onSpeakSelection: playSelection,
                    onWordStudy: { kind, excerpt in
                        speech.pause()
                        reader.openStudy(kind, at: excerpt)
                    }
                )
                .id(version)
            }
        }
        .frame(width: contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderPalette.paper)
    }

    private var articleRecordButtons: some View {
        let completed = reader.learningRecord?.reading.status == .completed
        return HStack(spacing: 8) {
            Button { sheet = .readingFeedback } label: {
                Label(completed ? "已完成阅读" : "完成阅读",
                      systemImage: completed ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(ReaderButtonStyle(prominent: false))
            .help(completed ? "更新阅读难度与反馈" : "记录读完和阅读难度")
            .accessibilityIdentifier("completeReading")

            Button { sheet = .favorites } label: {
                Label("\(reader.favoritesTitle) \(reader.favoriteCount)", systemImage: "star")
            }
            .buttonStyle(ReaderButtonStyle(prominent: false))
            .accessibilityIdentifier("articleFavorites")
        }
    }

    private var sentenceModeButton: some View {
        Button { preferences.clickWholeSentence.toggle() } label: {
            Label(preferences.clickWholeSentence ? "点整句已开启" : "点整句",
                  systemImage: preferences.clickWholeSentence ? "checkmark.circle.fill" : "text.cursor")
        }
        .buttonStyle(ReaderButtonStyle(prominent: preferences.clickWholeSentence, scale: 1.12))
        .accessibilityIdentifier("clickWholeSentence")
        .help(preferences.clickWholeSentence ? "点一下正文翻译整句。再次点击此按钮恢复查词。" : "开启后，点一下正文翻译整句")
    }

    private func playArticle(fromHere: Bool) {
        let plan = reader.articleForListening(fromHere: fromHere)
        speech.start(plan.sentences, at: plan.start)
    }

    private func playSelection(_ excerpt: TextExcerpt) {
        let sentences = reader.sentencesForListening(to: excerpt)
        guard let last = sentences.last else { return }
        speech.start(sentences, selectionContinuation: reader.listeningContinuation(after: last))
    }

    private var inspector: some View {
        let analysisBelowTranslation = reader.study == nil && reader.lookup?.kind == .translation
            && (reader.selection == nil || reader.selection?.range == reader.lookup?.excerpt.range)
        return ReaderInspector {
            VStack(alignment: .leading, spacing: 11) {
                inspectorHeading
                AssistantActions(selected: textAssistantAction, available: textAssistantAvailable,
                                 perform: performTextAssistantAction)
                studyMenu
                HStack(spacing: 8) {
                    action(.translation, shortcut: "⇧⌘T")
                    if !analysisBelowTranslation {
                        action(.analysis, shortcut: "⇧⌘G")
                    }
                }
                Text(!reader.hasEnglishReadingText || (reader.selection != nil && !reader.hasEnglishSelection)
                     ? "学习助手适用于英文正文"
                     : reader.selection.map { "已选中 \($0.text.count.formatted()) 个字符" }
                         ?? (preferences.clickWholeSentence ? "单击正文翻译整句" : "点词查词，拖选查询短语"))
                    .font(.system(size: max(11, 12 * interfaceScale)))
                    .foregroundStyle(ReaderPalette.muted)
                    .accessibilityIdentifier("selectionStatus")
                if let status = reader.hintStatus {
                    Button {
                        reader.openStudy(.hints)
                    } label: {
                        Label(status, systemImage: StudyKind.hints.symbol)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("assistStatus")
                }
            }
        } content: {
            if reader.shownFavorite == nil, let source = reader.assistantSource {
                AssistantSourceRow(sentence: source.text) { reader.locate(source.range) }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
            if let favorite = reader.shownFavorite {
                favoriteCard(favorite).id(favorite.id)
            } else if let study = reader.study {
                StudyCard(study: study, reader: reader, fontSize: fontSize,
                          retry: { reader.openStudy(study.kind, at: study.request?.target) },
                          dismiss: { reader.dismissStudy() },
                          reveal: { reader.revealStudyAnswer() },
                          locate: { reader.locate($0) },
                          detailedAnalysis: { reader.lookUp(.analysis, excerpt: $0) })
                    .id(study.id)
            } else if let lookup = reader.lookup {
                VStack(spacing: 0) {
                    lookupCard(lookup)
                    if lookup.kind == .translation {
                        translationAnalysisSection(for: lookup)
                    }
                }
                .id(lookup)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(ReaderPalette.accent)
                    Text(!reader.hasEnglishReadingText
                         ? "本页可直接阅读。学习助手适用于英文正文。" : "查词、译文和解析会显示在这里。")
                        .font(.system(size: 15, weight: .medium))
                    if reader.article.body == Article.sample.body {
                        Text("试着点示例里两处 bank，看看同一个词在不同句子里的意思。")
                            .font(.system(size: 13))
                            .lineSpacing(4)
                            .foregroundStyle(ReaderPalette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
        } footer: {
            AssistantQuestionPanel(reader: reader, mode: .text, materialID: reader.questionMaterialID,
                                   locate: locateQuestionSource, isActive: mode == .text,
                                   manualSelection: reader.questionSelection) { currentOnly in
                reader.assistantQuestionReference(currentOnly: currentOnly, spoken: speech.current)
            }
        }
        .onChange(of: reader.lookup) { copied = false }
    }

    private func locateQuestionSource(_ reference: AssistantQuestionReference, _ excerpt: NSRange?) async throws {
        guard let source = reference.source else { return }
        switch source.mode {
        case .text:
            try await reader.locateQuestionSource(reference, excerpt: excerpt)
            speech.stop()
        case .audio:
            try audio.locateQuestionSource(reference, excerpt: excerpt)
            showsSubtitles = true
        case .video:
            try await video.locateQuestionSource(reference, excerpt: excerpt)
        }
        try Task.checkCancellation()
        mode = source.mode
        let chat = reader.questionChat(for: source.mode)
        chat.activate(material: source.materialID)
        chat.replaceReference(with: reference)
    }

    private var inspectorHeading: some View {
        ReaderInspectorHeading(title: "学习助手", symbol: "text.bubble")
    }

    private var textAssistantAction: AssistantAction? {
        if reader.study?.kind == .phrase { return .phrase }
        if reader.study != nil || reader.shownFavorite != nil { return nil }
        switch reader.lookup?.kind {
        case .word: return .word
        case .analysis: return .sentence
        default: return nil
        }
    }

    private var textAssistantAvailable: Set<AssistantAction> {
        var available: Set<AssistantAction> = []
        if reader.assistantWordTarget != nil { available.formUnion([.word, .phrase]) }
        if reader.assistantSentenceTarget != nil || speech.current != nil { available.insert(.sentence) }
        return available
    }

    private func performTextAssistantAction(_ action: AssistantAction) {
        speech.pause()
        switch action {
        case .word:
            if let word = reader.assistantWordTarget, reader.study != nil || reader.shownFavorite != nil
                || reader.lookup?.excerpt != word || reader.lookup?.kind != .word {
                reader.lookUp(.word, excerpt: word)
            }
        case .phrase:
            if let word = reader.assistantWordTarget {
                reader.openStudy(.phrase, at: word, focusWord: word)
            }
        case .sentence:
            if let sentence = reader.assistantSentenceTarget ?? speech.current {
                reader.lookUp(.analysis, excerpt: sentence)
            }
        }
    }

    private var studyMenu: some View {
        Button { showsStudyTools.toggle() } label: {
            HStack(spacing: 9) {
                Label("助读工具", systemImage: "sparkle.magnifyingglass")
                Image(systemName: "chevron.down").font(.system(size: 16 * interfaceScale, weight: .semibold))
            }
        }
        .buttonStyle(ReaderButtonStyle(prominent: showsStudyTools, compact: true, scale: 2))
        .fixedSize()
        .accessibilityLabel("助读工具")
        .accessibilityIdentifier("studyMenu")
        .popover(isPresented: $showsStudyTools, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(StudyKind.allCases, id: \.rawValue) { kind in
                    Button {
                        showsStudyTools = false
                        reader.openStudy(kind)
                    } label: {
                        Label(kind.label, systemImage: kind.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.3))
                    .disabled(kind == .phrase && reader.focusedWord == nil)
                }
                Divider()
                Toggle("跟随阅读标记难点", isOn: Binding(get: { reader.assistedReading },
                                                           set: { reader.setAssistedReading($0) }))
                    .controlSize(.large)
            }
            .padding(14)
            .frame(width: 248)
        }
    }

    private func action(_ kind: LookupKind, shortcut: String) -> some View {
        Button {
            speech.pause()
            reader.lookUp(kind)
        } label: {
            Label(kind.label, systemImage: kind.symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ReaderButtonStyle(prominent: kind == .translation, compact: true))
        .disabled(!reader.hasEnglishSelection)
        .help("\(kind.label)（\(shortcut)）")
    }

    private func translationAnalysisSection(for lookup: LookupRequest) -> some View {
        let analysis = reader.translationAnalysis
        let isExpanded = analysis?.isExpanded == true
        return VStack(spacing: 8) {
            Button {
                reader.toggleTranslationAnalysis(for: lookup)
            } label: {
                HStack(spacing: 8) {
                    Label(isExpanded ? "收起语法解析" : LookupKind.analysis.label,
                          systemImage: LookupKind.analysis.symbol)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 2))
            .accessibilityIdentifier("analyzeTranslation")

            if let analysis, isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    translationSummary(analysis, for: lookup)
                    Button { reader.toggleTranslationDetails(lookup) } label: {
                        Label(analysis.detailsExpanded ? "收起完整讲解" : "展开完整讲解",
                              systemImage: analysis.detailsExpanded ? "chevron.up" : "chevron.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ReaderButtonStyle(prominent: false, scale: 1.12))
                    .accessibilityIdentifier("translationAnalysisDetails")
                    if analysis.detailsExpanded { translationDetails(analysis, for: lookup) }
                    if let draft = reader.grammarFavorite {
                        LearningFavoriteButton(reader: reader, draft: draft)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderPalette.rule, lineWidth: 1))
            }
        }
        .padding([.horizontal, .bottom], 16)
    }

    @ViewBuilder
    private func translationSummary(_ analysis: ReaderModel.TranslationAnalysis, for lookup: LookupRequest) -> some View {
        if let summary = analysis.summary {
            let includesMoreSentences = analysis.summaryRange.map { NSMaxRange($0) < NSMaxRange(lookup.excerpt.range) } ?? false
            CompactGrammarView(result: summary, firstSentenceOnly: includesMoreSentences,
                               fontSize: fontSize, locate: { reader.locate($0) })
                .accessibilityIdentifier("translationGrammarSummary")
        } else if analysis.isSummarizing {
            lookupProgress("")
        } else if let error = analysis.summaryError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(ReaderPalette.warning)
            Button("重试主干提示") { reader.summarizeTranslation(lookup) }.buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func translationDetails(_ analysis: ReaderModel.TranslationAnalysis, for lookup: LookupRequest) -> some View {
        if !analysis.answer.isEmpty {
            AnswerText(answer: analysis.answer, fontSize: max(17, min(32, fontSize * 0.8)))
                .accessibilityIdentifier("translationAnalysisAnswer")
        }
        if analysis.isLoading {
            HStack {
                lookupProgress(analysis.answer)
                Spacer()
                Button("停止") { reader.stopTranslationAnalysis() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        } else if let error = analysis.error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(ReaderPalette.warning)
            Button("重试") { reader.analyzeTranslation(lookup) }.buttonStyle(.link)
        } else if !analysis.finished {
            Button("重新解析") { reader.analyzeTranslation(lookup) }.buttonStyle(.link)
        }
    }

    private func favoriteCard(_ favorite: LearningFavorite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("已收藏 · \(favorite.kind.label)", systemImage: "star.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ReaderPalette.accent)
            Text(favorite.selectedText)
                .font(.system(size: 19, design: .serif))
                .textSelection(.enabled)
            Rectangle().fill(ReaderPalette.rule).frame(height: 1)
            let text = [favorite.result.definition, favorite.result.translation, favorite.result.analysis]
                .compactMap { $0 }.joined(separator: "\n\n")
            AnswerText(answer: text, fontSize: max(17, min(32, fontSize * 0.8)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderPalette.rule, lineWidth: 1))
        .padding(16)
        .accessibilityIdentifier("savedFavoriteCard")
    }

    private func lookupProgress(_ answer: String) -> some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(answer.isEmpty ? "等待本地模型…" : "正在生成…")
        }
        .font(.system(size: 13))
        .foregroundStyle(ReaderPalette.muted)
    }

    private func lookupCard(_ lookup: LookupRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(lookup.kind.label, systemImage: lookup.kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReaderPalette.accent)
                Spacer()
                if reader.isLookingUp {
                    Button("停止") { reader.cancelLookup() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                } else if !reader.answer.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reader.answer, forType: .string)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "已复制" : "复制结果")
                    .help(copied ? "已复制" : "复制结果")
                }
            }
            Text(lookup.excerpt.text)
                .font(.system(size: lookup.kind == .word ? min(36, max(25, fontSize + 3)) : min(19, max(15, fontSize * 0.65)), design: .serif))
                .lineLimit(lookup.kind == .word ? 3 : 4)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if lookup.kind == .word {
                ViewThatFits(in: .horizontal) {
                    HStack { wordActions(lookup.excerpt) }
                    VStack(alignment: .leading, spacing: 6) { wordActions(lookup.excerpt) }
                }
            }
            if lookup.kind == .analysis {
                Button { reader.openStudy(.structure, at: lookup.excerpt) } label: {
                    Label("先看主干", systemImage: StudyKind.structure.symbol)
                }
                .controlSize(.large)
                .accessibilityIdentifier("showSentenceStructure")
            }
            if !reader.isLookingUp, reader.lookupError == nil, !reader.answer.isEmpty,
               reader.canShowTranslationBelow(lookup) {
                Button { reader.toggleInlineTranslation(for: lookup) } label: {
                    Label(reader.isShowingTranslationBelow(lookup) ? "收起正文译文" : "在原文下显示",
                          systemImage: "text.append")
                }
                .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 2))
                .accessibilityIdentifier("showInlineTranslation")
            }
            if let draft = reader.lookupFavorite {
                LearningFavoriteButton(reader: reader, draft: draft)
            }
            Rectangle().fill(ReaderPalette.rule).frame(height: 1)

            if !reader.answer.isEmpty {
                AnswerText(answer: reader.answer, fontSize: max(17, min(32, fontSize * 0.8)))
                    .accessibilityIdentifier("lookupAnswer")
            }

            if let error = reader.lookupError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(ReaderPalette.warning)
                Button("重试") { reader.lookUp(lookup.kind, excerpt: lookup.excerpt) }
                    .buttonStyle(.link)
            } else if reader.isLookingUp {
                lookupProgress(reader.answer)
            } else if reader.answer.isEmpty {
                Button("重新查询") { reader.lookUp(lookup.kind, excerpt: lookup.excerpt) }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderPalette.rule, lineWidth: 1))
        .padding(16)
    }

    @ViewBuilder
    private func wordActions(_ excerpt: TextExcerpt) -> some View {
        Button { reader.translateSentence(containing: excerpt) } label: {
            Label("看整句", systemImage: "text.cursor")
        }
        .controlSize(.large)
        .fixedSize()
        .accessibilityIdentifier("selectWholeSentence")
        .help("选中整句并在右侧显示译文")
        if reader.focusedWord != nil {
            Button { reader.openStudy(.phrase, at: excerpt) } label: {
                Label("看完整搭配", systemImage: StudyKind.phrase.symbol)
            }
            .controlSize(.large)
            .fixedSize()
            .accessibilityIdentifier("showWordPhrase")
        }
        if reader.referenceWord != nil {
            Button { reader.openStudy(.reference, at: excerpt) } label: {
                Label("指代与省略", systemImage: StudyKind.reference.symbol)
            }
            .controlSize(.large)
            .fixedSize()
            .accessibilityIdentifier("showWordReference")
        }
    }

    private var connectionLabel: String {
        switch reader.connection {
        case .checking: "正在连接"
        case .connected: "LM Studio 已连接"
        case .unavailable: "LM Studio 未连接"
        }
    }

    private var connectionColor: Color {
        switch reader.connection {
        case .checking: ReaderPalette.muted
        case .connected: ReaderPalette.accent
        case .unavailable: ReaderPalette.warning
        }
    }
}

struct ReaderButtonStyle: ButtonStyle {
    let prominent: Bool
    var compact = false
    var scale: CGFloat = 1
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.readerInterfaceScale) private var interfaceScale

    func makeBody(configuration: Configuration) -> some View {
        let size = scale * interfaceScale
        let fill = !enabled ? ReaderPalette.disabled
            : primary ? ReaderPalette.primaryButton : prominent ? ReaderPalette.accentFill : ReaderPalette.button
        let ink = !enabled ? ReaderPalette.muted
            : primary ? ReaderPalette.onAccent : prominent ? ReaderPalette.accent : ReaderPalette.ink
        return configuration.label
            .font(.system(size: max(11, (compact ? 12 : 13) * size), weight: .semibold))
            .padding(.horizontal, (compact ? 8 : 12) * size)
            .frame(minHeight: max(24, (compact ? 33 : 32) * size))
            .foregroundStyle(ink)
            .background(fill, in: RoundedRectangle(cornerRadius: 7 * size))
            .overlay(RoundedRectangle(cornerRadius: 7 * size).strokeBorder(
                primary && enabled ? ReaderPalette.primaryButton : ReaderPalette.rule, lineWidth: 1))
            .opacity(configuration.isPressed && enabled ? 0.78 : 1)
            .contentShape(Rectangle())
    }
}

struct AnswerText: View {
    let answer: String
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            let lines = answer.components(separatedBy: .newlines)
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Color.clear.frame(height: 3).accessibilityHidden(true)
                } else {
                    let isHeading = line.hasPrefix("#")
                    let content = isHeading ? String(line.drop(while: { $0 == "#" || $0 == " " }))
                        : line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line
                    let attributed = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(content)
                    Text(attributed)
                        .font(.system(size: fontSize, weight: isHeading ? .semibold : .regular))
                        .foregroundStyle(isHeading ? ReaderPalette.accent : ReaderPalette.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
