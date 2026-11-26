import SwiftUI

struct PlaybackTimelineControl: NSViewRepresentable {
    let value: Double
    let duration: Double
    let onValueChanged: (Double, Bool) -> Void
    let onEditingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> PlaybackTimelineSlider {
        let slider = PlaybackTimelineSlider()
        slider.setAccessibilityLabel("视频进度")
        slider.setAccessibilityIdentifier("playbackPosition")
        return slider
    }

    func updateNSView(_ slider: PlaybackTimelineSlider, context: Context) {
        slider.onValueChanged = onValueChanged
        slider.onEditingChanged = onEditingChanged
        slider.updatePlayback(value: value, duration: duration)
    }
}

final class PlaybackTimelineSlider: NSSlider {
    var onValueChanged: ((Double, Bool) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    private(set) var isUserTracking = false

    init() {
        super.init(frame: .zero)
        isContinuous = true
        target = self
        action = #selector(userChangedValue)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updatePlayback(value: Double, duration: Double) {
        minValue = 0
        maxValue = max(1, duration)
        if !isUserTracking { doubleValue = max(minValue, min(value, maxValue)) }
    }

    override func mouseDown(with event: NSEvent) {
        isUserTracking = true
        onEditingChanged?(true)
        super.mouseDown(with: event)
        onValueChanged?(doubleValue, true)
        isUserTracking = false
        onEditingChanged?(false)
    }

    @objc private func userChangedValue() {
        onValueChanged?(doubleValue, isUserTracking)
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let value = accessibilityValue as? NSNumber else { return }
        doubleValue = max(minValue, min(value.doubleValue, maxValue))
        onValueChanged?(doubleValue, false)
    }
}


private struct SubtitleTrackMenu: View {
    @ObservedObject var model: VideoStudyModel
    let language: SubtitleLanguage

    private var languageName: String {
        switch language {
        case .english: "英文"
        case .chinese: "中文"
        }
    }

    private var selectedTrackID: Int? {
        switch language {
        case .english: model.selectedEnglishEmbeddedTrackID
        case .chinese: model.selectedChineseEmbeddedTrackID
        }
    }

    private var hasLoadedSubtitle: Bool {
        switch language {
        case .english: !model.englishCues.isEmpty
        case .chinese: !model.chineseCues.isEmpty
        }
    }

    var body: some View {
        Menu {
            Button("加载外部 \(languageName) SRT…") {
                if let url = FilePanelService.chooseSubtitle(languageName: languageName) {
                    model.loadSubtitle(url, language: language)
                }
            }

            if language == .english {
                Divider()
                Picker("阅读模式", selection: Binding(get: { model.englishReadingMode }, set: model.setEnglishReadingMode)) {
                    ForEach(EnglishReadingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.inline)
                if model.isListeningFirst {
                    Text("先听后看锁定整句；退出后恢复所选阅读模式")
                }
            }

            if !model.embeddedSubtitleTracks.isEmpty {
                Divider()
                Section("视频内字幕") {
                    ForEach(model.embeddedSubtitleTracks) { track in
                        Button {
                            model.loadEmbeddedSubtitle(track, language: language)
                        } label: {
                            if selectedTrackID == track.id {
                                Label(track.displayName, systemImage: "checkmark")
                            } else {
                                Text(track.displayName)
                            }
                        }
                        .disabled(!track.isTextBased)
                    }
                }
            }

            if hasLoadedSubtitle {
                Divider()
                Button("关闭\(languageName)字幕") {
                    model.clearSubtitle(language: language)
                }
            }
        } label: {
            Text("\(languageName)字幕")
        }
    }
}


struct VideoStudyContent: View {
    @ObservedObject var model: VideoStudyModel
    let fontSize: Double
    let subtitleWidth: CGFloat
    let chooseVideo: () -> Void
    let openHistory: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if model.isPreparingMedia {
                    ProgressView(model.mediaPreparationMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.currentSourceVideoURL != nil {
                    VideoStudyPicture(model: model, controller: model.playerController)
                    if model.canNavigateSubtitles || !model.chineseCues.isEmpty || model.subtitleNotice != nil {
                        SubtitleBar(model: model, fontSize: fontSize, availableHeight: geometry.size.height)
                            .frame(maxWidth: subtitleWidth)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView {
                        Label("视频精学", systemImage: "play.rectangle")
                    } description: {
                        Text("拖入视频，或从历史记录继续。")
                    } actions: {
                        Button("导入视频", action: chooseVideo)
                            .buttonStyle(ReaderButtonStyle(prominent: true, compact: true, scale: 1.5))
                        Button("历史记录", action: openHistory)
                            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .dropDestination(for: URL.self) { files, _ in model.openDroppedVideo(files) }
        .alert("视频精学", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) { Button("好") { model.alertMessage = nil } } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

private struct VideoStudyPicture: View {
    let model: VideoStudyModel
    @ObservedObject var controller: PlayerController

    var body: some View {
        ZStack {
            Color.black
            if controller.usesVLC {
                VLCPlayerView(controller: controller, openVideo: model.openDroppedVideoFile)
            } else {
                NativePlayerView(player: controller.player, openVideo: model.openDroppedVideoFile)
            }
            if controller.isStarting {
                ProgressView().controlSize(.large).tint(.white)
                    .padding(12).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("videoPicture")
    }
}

struct VideoPlayerBar: View {
    @ObservedObject var model: VideoStudyModel
    @ObservedObject var controller: PlayerController
    @Environment(\.readerInterfaceScale) private var scale
    @State private var scrubValue: Double?

    var body: some View {
        if model.isPreparingMedia || model.currentSourceVideoURL != nil {
            playbackBar
        }
    }

    private var playbackBar: some View {
        let previous: (() -> Void)? = model.canStep(by: -1) ? { model.step(by: -1) } : nil
        let next: (() -> Void)? = model.canStep(by: 1) ? { model.step(by: 1) } : nil
        let replay: (() -> Void)? = model.canReplaySentence ? { model.replaySentence() } : nil
        return ReaderPlaybackBar(idPrefix: "video", isPlaying: model.willPlayVideo, status: status,
                                 previous: previous, toggle: model.togglePlayback, next: next, replay: replay,
                                 close: model.closeVideo, extraShortcut: extraShortcut) {
            if !model.isPreparingMedia { progress }
        } accessory: {
            PlaybackSpeedMenu(rate: controller.playbackRate,
                              speeds: [0.5, 0.75, 1, 1.2, 1.25, 1.5, 2], onSelect: { controller.playbackRate = $0 },
                              id: "videoPlaybackSpeed", help: "调整视频播放速度")
                .disabled(model.isPreparingMedia)
            soundControls.disabled(model.isPreparingMedia)
        }
    }

    private var status: String {
        if model.isPreparingMedia { return model.mediaPreparationMessage }
        if model.isListeningFirst { return model.listeningStatusTitle }
        if model.hasFinishedListeningPass { return "可跟读 · 等待下一句" }
        if controller.pendingSeekMilliseconds != nil { return "正在定位" }
        if model.isSentenceLoopEnabled { return "单句循环" }
        return controller.isPlaying ? "播放中" : "已暂停"
    }

    private var progress: some View {
        let duration = max(controller.durationMilliseconds, model.currentVideoRecord?.durationMilliseconds ?? 0)
        return HStack(spacing: 10 * scale) {
            Text(SubtitleTimeLabel.string(scrubValue.map { Int64($0.rounded()) } ?? controller.currentMilliseconds))
                .monospacedDigit()
            PlaybackTimelineControl(value: Double(controller.currentMilliseconds), duration: Double(duration),
                                    onValueChanged: { value, tracking in
                if tracking { scrubValue = value }
                else { model.seekPlayback(toMilliseconds: Int64(value.rounded())) }
            }, onEditingChanged: { editing in
                if editing { scrubValue = Double(controller.currentMilliseconds) }
                else if let value = scrubValue {
                    scrubValue = nil
                    model.seekPlayback(toMilliseconds: Int64(value.rounded()))
                }
            })
            .frame(height: 20 * scale)
            Text(SubtitleTimeLabel.string(duration)).monospacedDigit()
        }
        .font(.system(size: 14 * scale))
        .foregroundStyle(ReaderPalette.muted)
    }

    private var soundControls: some View {
        HStack(spacing: 6 * scale) {
            VideoSoundMenu(model: model, controller: controller)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.65))
            .accessibilityLabel("全屏")
        }
    }

    private func extraShortcut(_ event: NSEvent) -> (() -> Void)? {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(modifiers) == .option else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where model.canAnalyzeCurrentSubtitle: return model.analyzeCurrentSubtitle
        case "h" where model.canAdvanceListeningStage: return model.revealSubtitle
        case "l" where model.canLoopCurrentSentence || model.isSentenceLoopEnabled: return model.toggleSentenceLoop
        default: return nil
        }
    }
}

private struct VideoSoundMenu: View {
    let model: VideoStudyModel
    @ObservedObject var controller: PlayerController
    @Environment(\.readerInterfaceScale) private var scale
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: { Image(systemName: "speaker.wave.2") }
            .buttonStyle(ReaderButtonStyle(prominent: isPresented, compact: true, scale: 1.65))
            .accessibilityLabel("音量、音轨与快进")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12 * scale) {
                    Slider(value: $controller.volume, in: 0...1) { Text("音量") }
                    if !controller.availableAudioTracks.isEmpty {
                        Picker("音轨", selection: Binding(get: { controller.selectedAudioTrackID }, set: { id in
                            if let id { controller.selectAudioTrack(id) }
                        })) {
                            ForEach(controller.availableAudioTracks) { track in Text(track.name).tag(Optional(track.id)) }
                        }
                    }
                    HStack {
                        Button("后退 5 秒") { model.skipPlayback(milliseconds: -5_000); isPresented = false }
                        Button("前进 5 秒") { model.skipPlayback(milliseconds: 5_000); isPresented = false }
                    }
                }
                .font(.system(size: 14 * scale))
                .padding(14 * scale)
                .frame(width: 270 * scale)
            }
    }
}

struct VideoHistorySheet: View {
    @ObservedObject var model: VideoStudyModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("视频历史").font(.title2.bold())
            if model.recentVideos.isEmpty {
                ContentUnavailableView("暂无历史视频", systemImage: "clock")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.recentVideos) { record in
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.displayName).font(.headline).lineLimit(2)
                                    Text(SubtitleTimeLabel.string(record.lastPositionMilliseconds))
                                        .foregroundStyle(ReaderPalette.muted)
                                }
                                Spacer()
                                if record.sourceExists {
                                    Button("继续播放") { dismiss(); model.continueVideo(record) }
                                        .accessibilityIdentifier("resumeVideo")
                                } else {
                                    Button("重新定位…") {
                                        if let url = FilePanelService.chooseVideo() {
                                            dismiss()
                                            model.relinkVideo(record, to: url)
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 630, height: 490)
        .background(ReaderPalette.panel)
    }
}

struct VideoStudyTools: View {
    @ObservedObject var model: VideoStudyModel
    @Environment(\.readerInterfaceScale) private var scale
    @State private var showsTools = false
    @State private var showsCalibration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8 * scale) { tools; transcript }
                VStack(alignment: .leading, spacing: 8 * scale) { tools; transcript }
            }
            if model.isListeningFirst {
                Button(model.revealButtonTitle, action: model.revealSubtitle)
                    .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.25))
                    .help("切换字幕阶段并播放当前句（⌥H）")
                    .disabled(!model.canAdvanceListeningStage)
            }
        }
    }

    private var transcript: some View {
        Button {
            model.sidebarMode = .transcript
        } label: {
            Label("文稿", systemImage: "list.bullet.rectangle")
        }
        .buttonStyle(ReaderButtonStyle(prominent: model.sidebarMode == .transcript, compact: true))
        .accessibilityIdentifier("videoTranscript")
        .disabled(model.currentSourceVideoURL == nil)
    }

    private var tools: some View {
        Button { showsTools.toggle() } label: {
            HStack(spacing: 8 * scale) {
                Label("字幕工具", systemImage: "captions.bubble")
                Image(systemName: "chevron.down").imageScale(.small)
            }
        }
        .buttonStyle(ReaderButtonStyle(prominent: showsTools, compact: true, scale: 1.25))
        .fixedSize()
        .accessibilityIdentifier("videoSubtitleTools")
        .disabled(model.currentSourceVideoURL == nil)
        .onChange(of: showsTools) { if !showsTools { showsCalibration = false } }
        .popover(isPresented: $showsTools, arrowEdge: .bottom) {
            if showsCalibration {
                VideoSubtitleCalibration(model: model, isPresented: $showsCalibration)
            } else {
                toolOptions
            }
        }
    }

    private var toolOptions: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                SubtitleTrackMenu(model: model, language: .english)
                SubtitleTrackMenu(model: model, language: .chinese)
            }
            .controlSize(.large)
            .font(.system(size: 16 * scale))

            toolButton("字幕校时…", symbol: "clock.arrow.2.circlepath") { showsCalibration = true }
            if !model.sentenceBoundaryEdits.isEmpty || model.hasSentenceBoundaryOverrides {
                Menu("调整句界") {
                    ForEach(model.sentenceBoundaryEdits) { edit in
                        Button(edit.title) { model.applySentenceBoundaryEdit(edit) }
                    }
                    if model.hasSentenceBoundaryOverrides {
                        Button("恢复本轨道自动句界", action: model.resetSentenceBoundaries)
                    }
                }
                .disabled(!model.canUseSubtitleAtPlaybackPosition)
            }
            toolButton(model.isListeningFirst ? "退出先听后看" : "先听后看", symbol: "ear") {
                model.setListeningFirst(!model.isListeningFirst)
                showsTools = false
            }
            .disabled(!model.isListeningFirst && !model.canStartListeningFirst)

            toolButton(model.isSentenceLoopEnabled ? "停止单句循环" : "单句循环（⌥L）", symbol: "repeat.1") {
                model.toggleSentenceLoop()
                showsTools = false
            }
            .disabled(!model.canLoopCurrentSentence && !model.isSentenceLoopEnabled)
        }
        .frame(width: 234 * scale)
        .padding(10 * scale)
        .background(ReaderPalette.chrome)
        .environment(\.readerInterfaceScale, scale)
    }

    private func toolButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.25))
    }
}
