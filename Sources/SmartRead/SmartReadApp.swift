import SwiftUI

enum ReaderMode: String, CaseIterable, Codable, Sendable {
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
                Button("临时朗读选中句子") {
                    if let sentence = reader.selectedPreviewSentence { speech.preview(sentence) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(mode != .text || reader.selectedPreviewSentence == nil || sheet != nil)
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
    case importArticle, history, audioHistory, videoHistory, readingFeedback, favorites, listeningMarks
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
    @State private var showsModeMenu = false
    @State private var showsDisplayOptions = false
    @State private var editingCue: AudioStudyCue?
    @State private var pendingPDF: URL?
    @State private var pdfBookPanel: PDFBookPanel?
    @State private var dropTarget = false
    @State private var subtitleAssistant = AudioSubtitleAssistant()
    @State private var pendingMarkedSpeech: (version: UUID, sentence: TextExcerpt)?

    private var interfaceScale: CGFloat { preferences.interfaceSize.scale }
    private static let brandIcon: NSImage? = {
        let url = Bundle.main.url(forResource: "SmartRead", withExtension: "icns")
            ?? Bundle.module.url(forResource: "SmartRead", withExtension: "icns")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()
    private static let markConfirmationSound: NSSound? = {
        guard let url = Bundle.module.url(forResource: "ListeningMark", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        return sound
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
                    if audio.entry != nil {
                        AudioPlayerBar(model: audio, captureMark: captureListeningMark, trackedReplay: trackedReplay)
                    }
                case .text:
                    if speech.current != nil {
                        SpeechPlayerBar(speech: speech, captureMark: captureListeningMark, trackedReplay: trackedReplay)
                    }
                case .video:
                    VideoPlayerBar(model: video, controller: video.playerController,
                                   captureMark: captureListeningMark, trackedReplay: trackedReplay)
                }
            }
        }
        .foregroundStyle(ReaderPalette.ink)
        .background(ReaderPalette.paper)
        .background(PlaybackShortcutMonitor(action: readingShortcut))
        .tint(ReaderPalette.primaryButton)
        .task {
            speech.warmUp()
            await reader.connect()
        }
        .onChange(of: articleVersion) { _, version in
            speech.stop()
            if let pending = pendingMarkedSpeech, pending.version == version {
                playMarkedSentence(pending.sentence)
            }
            pendingMarkedSpeech = nil
        }
        .onChange(of: speech.error) { _, message in
            if mode == .text, speech.current == nil, let message { reader.notice = message }
        }
        .onChange(of: audio.entry?.id) { subtitleAssistant.clear() }
        .onChange(of: showsSubtitles) {
            if !showsSubtitles { subtitleAssistant.clear() }
        }
        .onChange(of: mode) { previous, next in
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
            case .listeningMarks:
                ListeningMarkSheet(rows: reader.listeningMarks.rows(for: mode, materialID: listeningMaterialID),
                                   issue: reader.listeningMarks.issue,
                                   passage: { liveAudioCue(for: $0)?.text ?? $0.passage },
                                   location: { mark in
                    liveAudioCue(for: mark).map { audioTimeText($0.start) } ?? mark.locationLabel
                }, open: reviewListeningMark, remove: reader.listeningMarks.remove,
                                   isFavorite: isListeningFavorite, toggleFavorite: toggleListeningFavorite)
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

    private func readingShortcut(_ shortcut: PlaybackShortcut) -> (() -> Void)? {
        guard shortcut == .toggle, mode == .text, speech.current == nil,
              sheet == nil, pdfBookPanel == nil, let sentence = reader.selectedPreviewSentence else { return nil }
        return { speech.preview(sentence) }
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
                                      selection: subtitleAssistant.selection, markedCues: markedAudioCues,
                                      lookUp: lookUpSubtitle, edit: editCue)
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
                                      clickWholeSentence: preferences.clickWholeSentence,
                                      listeningMarks: currentListeningMarks,
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
                                        fontSize: fontSize, showsSubtitles: $showsSubtitles,
                                        clickWholeSentence: preferences.$clickWholeSentence, edit: editCue,
                                        locateQuestionSource: locateQuestionSource)
                }
                if inVideoMode {
                    VideoStudyInspector(model: video, reader: reader, clickWholeSentence: preferences.$clickWholeSentence,
                                        listeningMarks: currentListeningMarks,
                                        locateQuestionSource: locateQuestionSource)
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
                listeningMarkButton
                Spacer(minLength: 8)
                displayControls(articleWidthPercent: articleWidthPercent)
                modeButton(showTitle: true)
                settingsLink(showStatus: true)
            }
            HStack(spacing: 10 * interfaceScale) {
                toolbarPrimary
                listeningMarkButton
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
                HStack(spacing: 10 * interfaceScale) {
                    displayControls(articleWidthPercent: articleWidthPercent)
                    listeningMarkButton
                }
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

    private var listeningMarkButton: some View {
        let count = currentListeningMarks.count
        return Button { sheet = .listeningMarks } label: {
            Label(count > 0 ? "听力标记 \(count)" : "听力标记", systemImage: "bookmark")
        }
        .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.6))
        .fixedSize()
        .accessibilityIdentifier("openListeningMarks")
        .help(reader.listeningMarks.issue ?? "双按 ↓ 或按 M 标记当前句，点击复盘")
        .disabled(listeningMaterialID == nil)
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
              let selection = AudioSubtitleSelection(entry: entry, cueID: cueID, target: target,
                                                     wholeSentence: preferences.clickWholeSentence
                                                         && !target.text.contains(where: \.isWhitespace)) else { return }
        if audio.isPlaying { audio.pause() }
        audio.selectQuestionReference(selection)
        subtitleAssistant.select(selection, using: reader)
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
                    listeningMarks: mode == .text ? reader.textListeningMarks : [],
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
                    onSpeakSelection: { selection in
                        if let sentence = reader.previewSentence(selection) { speech.preview(sentence) }
                    },
                    onCancelMark: { id in
                        reader.listeningMarks.remove(id)
                        if let issue = reader.listeningMarks.issue { reader.notice = issue }
                    },
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
        speech.start(plan.sentences, at: plan.start, stopsAfterSentence: !fromHere)
    }

    private func playSelection(_ excerpt: TextExcerpt) {
        let sentences = reader.sentencesForListening(to: excerpt)
        guard let last = sentences.last else { return }
        speech.start(sentences, selectionContinuation: reader.listeningContinuation(after: last))
    }

    private var inspector: some View {
        AssistantInspector(reader: reader, mode: .text, materialID: reader.questionMaterialID,
                           locate: locateQuestionSource, isActive: mode == .text,
                           manualSelection: reader.questionSelection, visiblePassage: textAssistantPassage,
                           sentenceFavorite: reader.sentenceFavoriteExcerpt.map { .init(reader: reader, excerpt: $0) },
                           reference: { reader.assistantQuestionReference(currentOnly: $0, spoken: speech.current) }) {
            textAssistantTools
        } content: {
            if let favorite = reader.shownFavorite {
                favoriteCard(favorite).id(favorite.id)
            } else if let study = reader.study {
                StudyCard(study: study, reader: reader, fontSize: fontSize,
                          retry: { reader.openStudy(study.kind, at: study.request?.target) },
                          dismiss: { reader.dismissStudy() }, reveal: { reader.revealStudyAnswer() },
                          locate: { reader.locate($0) }, detailedAnalysis: { reader.lookUp(.analysis, excerpt: $0) })
                    .id(study.id)
            } else if let lookup = reader.lookup {
                textAssistantResults(lookup)
            } else {
                Text(!reader.hasEnglishReadingText ? "本页可直接阅读。学习助手适用于英文正文。"
                     : preferences.clickWholeSentence ? "点击正文查看整句翻译。"
                     : "点击单词查看词义和例句译文。")
                    .font(.system(size: 13))
                    .foregroundStyle(ReaderPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
    }

    private var textAssistantPassage: String? {
        guard reader.study == nil, reader.shownFavorite == nil, let request = reader.assistantTranslation else { return nil }
        return reader.assistantDisplayExcerpt(request.excerpt).text
    }

    private func textAssistantResults(_ lookup: LookupRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if lookup.kind == .word {
                AssistantSectionTitle(title: "词义")
                Text(lookup.excerpt.text)
                    .font(.system(size: 25, weight: .semibold, design: .serif))
                    .textSelection(.enabled)
                textLookupAnswer(lookup, wordOnly: true)
                if let draft = reader.lookupFavorite {
                    LearningFavoriteButton(reader: reader, draft: draft, controlScale: 1)
                }
                Divider()
            }

            if let translation = reader.assistantTranslation {
                let excerpt = reader.assistantDisplayExcerpt(translation.excerpt)
                let relative = lookup.excerpt.range.location - excerpt.range.location
                let focus = lookup.kind == .word && relative >= 0
                    ? NSRange(location: relative, length: lookup.excerpt.range.length) : nil
                AssistantPassage(sentence: excerpt.text, focus: focus)
                if lookup.kind == .word {
                    AssistantResult(result: reader.wordTranslation.result, fontSize: assistantFontSize,
                                    cancel: reader.wordTranslation.cancel, retry: reader.retryWordTranslation)
                } else {
                    textLookupAnswer(lookup)
                }
                translationAnalysisSection(for: translation)
            } else if lookup.kind == .analysis {
                AssistantSectionTitle(title: "语法解析")
                Text(reader.assistantDisplayExcerpt(lookup.excerpt).text)
                    .font(.system(size: 17, design: .serif)).textSelection(.enabled)
                textLookupAnswer(lookup)
                if let draft = reader.lookupFavorite {
                    LearningFavoriteButton(reader: reader, draft: draft, controlScale: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var assistantFontSize: Double { max(15, min(28, fontSize * 0.72)) }

    private func textLookupAnswer(_ lookup: LookupRequest, wordOnly: Bool = false) -> some View {
        let answer = wordOnly ? reader.answer.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("搭配：") }.joined(separator: "\n") : reader.answer
        return Group {
            if !answer.isEmpty {
                AnswerText(answer: answer, fontSize: assistantFontSize)
                    .accessibilityIdentifier("lookupAnswer")
            }
            if reader.isLookingUp {
                HStack {
                    lookupProgress(answer)
                    Spacer()
                    Button("停止", action: reader.cancelLookup).buttonStyle(.link).font(.caption)
                }
            } else if let error = reader.lookupError {
                Text(error).font(.caption).foregroundStyle(ReaderPalette.warning)
                Button("重试") { reader.lookUp(lookup.kind, excerpt: lookup.excerpt) }.buttonStyle(.link)
            } else if answer.isEmpty {
                Button("重新查询") { reader.lookUp(lookup.kind, excerpt: lookup.excerpt) }.buttonStyle(.link)
            }
        }
    }

    private var listeningMaterialID: String? {
        switch mode {
        case .text:
            if let pdf = reader.article.pdfPage { return "book:\(pdf.book.id)" }
            return reader.questionMaterialID
        case .audio: return audio.entry?.id.uuidString
        case .video: return video.currentSourceVideoURL?.absoluteString
        }
    }

    private var currentListeningMarks: [ListeningMark] {
        reader.listeningMarks.marks(for: mode, materialID: listeningMaterialID)
    }

    private var markedAudioCues: Set<UUID> {
        Set(currentListeningMarks.compactMap { mark in
            guard case let .audio(_, cue, _) = mark.source.location else { return nil }
            return cue
        })
    }

    private func liveAudioCue(for mark: ListeningMark) -> AudioStudyCue? {
        guard case let .audio(entry, cue, _) = mark.source.location, audio.entry?.id == entry else { return nil }
        return audio.cues.first { $0.id == cue }
    }

    private func captureListeningMark() -> (() -> Void)? {
        let sourceMode = mode
        let material = listeningMaterialID
        let version = reader.articleVersion
        let source: ListeningTarget
        switch mode {
        case .text:
            guard let sentence = speech.lastSpoken, let reference = reader.questionReference(for: sentence) else { return nil }
            source = ListeningTarget(reference: reference)
        case .audio:
            guard let marked = audio.listeningMarkReference() else { return nil }
            source = ListeningTarget(reference: marked.reference, milliseconds: marked.time)
        case .video:
            guard let marked = video.listeningMarkReference() else { return nil }
            source = ListeningTarget(reference: marked.reference, milliseconds: marked.time)
        }
        return {
            guard self.mode == sourceMode, listeningMaterialID == material,
                  sourceMode != .text || reader.articleVersion == version,
                  reader.listeningMarks.add(source.reference, milliseconds: source.milliseconds) else { return }
            if preferences.listeningMarkSound { Self.markConfirmationSound?.play() }
        }
    }

    private var trackedReplay: () -> Void {
        let sourceMode = mode
        let material = listeningMaterialID
        let version = reader.articleVersion
        let record = recordReplay
        return {
            guard self.mode == sourceMode, listeningMaterialID == material,
                  sourceMode != .text || reader.articleVersion == version else { return }
            switch sourceMode {
            case .text:
                let reference = speech.current.flatMap(reader.questionReference(for:))
                speech.replay { speed in
                    if let reference { record(.init(reference: reference), speed) }
                }
            case .audio:
                audio.replay(onStarted: record)
            case .video:
                video.replaySentence(onStarted: record)
            }
        }
    }

    private var recordReplay: (ListeningTarget, PlaybackSpeed) -> Void {
        let marks = reader.listeningMarks
        return { marks.recordReplay($0, speed: $1) }
    }

    private func isListeningFavorite(_ mark: ListeningMark) -> Bool {
        mark.source.mode == .text ? reader.originalFavoriteID(for: mark) != nil : mark.isSaved == true
    }

    private func toggleListeningFavorite(_ mark: ListeningMark) async throws {
        if mark.source.mode == .text {
            try await reader.toggleOriginalFavorite(for: mark)
        } else {
            try reader.listeningMarks.toggleMediaFavorite(mark.id)
        }
    }

    private func reviewListeningMark(_ mark: ListeningMark, _ replay: Bool) async throws {
        guard mode == mark.source.mode, listeningMaterialID == mark.materialID else { return }
        switch mark.source.location {
        case .text(_, let range, _):
            let version = reader.articleVersion
            try await reader.locateQuestionSource(mark.reference, excerpt: nil)
            speech.stop()
            guard replay, let sentence = reader.listeningSentence(at: range) else { return }
            if reader.articleVersion != version {
                pendingMarkedSpeech = (reader.articleVersion, sentence)
            } else {
                playMarkedSentence(sentence)
            }
        case .audio:
            guard let cue = liveAudioCue(for: mark), let entry = audio.entry else {
                throw ReaderError.message("这条音频字幕已不存在。")
            }
            showsSubtitles = true
            if replay {
                audio.playCue(cue.id, onReplayStarted: recordReplay)
            } else {
                audio.locateCue(cue.id)
                if let selection = AudioSubtitleSelection(entry: entry, cueID: cue.id) {
                    audio.selectQuestionReference(selection)
                }
            }
        case .video:
            try await video.locateQuestionSource(mark.reference, excerpt: nil, reviewMark: replay,
                                                 onReplayStarted: recordReplay)
        }
    }

    private func playMarkedSentence(_ sentence: TextExcerpt) {
        let reference = reader.questionReference(for: sentence)
        let record = recordReplay
        let onStarted: (PlaybackSpeed) -> Void = { speed in
            if let reference { record(.init(reference: reference), speed) }
        }
        let passage = reader.articleForListening(fromHere: false).sentences
        if let start = passage.firstIndex(where: { $0.range == sentence.range }) {
            speech.start(passage, at: start, stopsAfterSentence: true, onStarted: onStarted)
        } else {
            speech.start([sentence], stopsAfterSentence: true, onStarted: onStarted)
        }
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

    @ViewBuilder
    private var textAssistantTools: some View {
        Button("翻译选区") { speech.pause(); reader.lookUp(.translation) }
            .disabled(!reader.hasEnglishSelection)
        if let word = reader.assistantWordTarget {
            Button("查词") { speech.pause(); reader.lookUp(.word, excerpt: word) }
            Button(StudyKind.phrase.label) {
                speech.pause()
                reader.openStudy(.phrase, at: word, focusWord: word)
            }
        }
        if let sentence = reader.assistantSentenceTarget ?? speech.current,
           reader.assistantTranslation == nil || reader.study != nil {
            Button("看整句翻译") { speech.pause(); reader.translateSentence(containing: sentence) }
            Button("语法解析") { speech.pause(); reader.lookUp(.analysis, excerpt: sentence) }
        }
        if let source = reader.assistantTranslation?.excerpt ?? reader.assistantSource {
            Button("回到原文") { reader.locate(source.range) }
                .accessibilityIdentifier("assistantReturnToSource")
        }
        if let translation = reader.assistantTranslation,
           let text = reader.translationText(for: translation) {
            if reader.lookup?.kind == .word {
                Button("复制译文") { copyAssistantResult(text) }
            }
            if reader.canShowTranslationBelow(translation) {
                Button(reader.isShowingTranslationBelow(translation) ? "收起正文译文" : "在原文下显示") {
                    reader.toggleInlineTranslation(for: translation)
                }
                .accessibilityIdentifier("showInlineTranslation")
            }
        }
        if !reader.answer.isEmpty, reader.lookup != nil, reader.study == nil {
            Button("复制结果") { copyAssistantResult(reader.answer) }
        }
        Menu("助读工具") {
            ForEach(StudyKind.allCases.filter { $0 != .phrase }, id: \.rawValue) { kind in
                Button(kind == .hints ? reader.hintStatus ?? kind.label : kind.label) {
                    speech.pause()
                    reader.openStudy(kind)
                }
            }
            Toggle("跟随阅读标记难点", isOn: Binding(get: { reader.assistedReading }, set: reader.setAssistedReading))
        }
    }

    private func translationAnalysisSection(for lookup: LookupRequest) -> some View {
        let analysis = reader.translationAnalysis
        let isExpanded = analysis?.isExpanded == true
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            AssistantGrammarRow(isExpanded: isExpanded) { reader.toggleTranslationAnalysis(for: lookup) }
            if let analysis, isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    translationSummary(analysis, for: lookup)
                    Button(analysis.detailsExpanded ? "收起完整讲解" : "展开完整讲解") {
                        reader.toggleTranslationDetails(lookup)
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("translationAnalysisDetails")
                    if analysis.detailsExpanded { translationDetails(analysis, for: lookup) }
                    if let draft = reader.grammarFavorite {
                        LearningFavoriteButton(reader: reader, draft: draft, controlScale: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
            }
            Divider()
        }
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
            Text(favorite.displayQuote)
                .font(.system(size: 19, design: .serif))
                .accessibilityIdentifier("savedFavoriteQuotation")
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
