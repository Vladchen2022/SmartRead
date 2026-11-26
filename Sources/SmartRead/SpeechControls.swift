import AVFoundation
import SwiftUI

struct SpeechMenu: View {
    let speech: ReaderSpeech
    let selection: TextExcerpt?
    let playArticle: (Bool) -> Void
    let playSelection: (TextExcerpt) -> Void
    @Environment(\.readerInterfaceScale) private var interfaceScale
    @State private var isPresented = false
    @State private var expandedPicker: String?

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8 * interfaceScale) {
                Label("听读", systemImage: "speaker.wave.2")
                Image(systemName: "chevron.down").imageScale(.small)
            }
        }
        .buttonStyle(ReaderButtonStyle(prominent: isPresented, compact: true, scale: 2))
        .fixedSize()
        .accessibilityLabel("听读")
        .accessibilityIdentifier("speechMenu")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6 * interfaceScale) {
                SpeechOptionPicker(
                    title: "播放倍速", id: "speechStartPlaybackSpeed",
                    selection: Binding(get: { speech.playbackSpeed }, set: speech.setPlaybackSpeed),
                    choices: PlaybackSpeed.allCases.map { ($0, $0.title) }, expandedPicker: $expandedPicker
                )
                Divider()
                playButton("朗读全文", id: "speakArticle") { playArticle(false) }
                playButton("从这里听", id: "speakFromHere") { playArticle(true) }
                if let selection {
                    playButton("朗读选区", id: "speakSelection") { playSelection(selection) }
                }
                Divider()
                SpeechOutputOptions(speech: speech, expandedPicker: $expandedPicker)
            }
            .padding(10 * interfaceScale)
            .frame(width: 280 * interfaceScale)
            .background(ReaderPalette.chrome)
            .environment(\.readerInterfaceScale, interfaceScale)
        }
        .onChange(of: isPresented) { _, open in
            if !open { expandedPicker = nil }
        }
    }

    private func playButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.55))
        .accessibilityIdentifier(id)
    }
}

struct SpeechOutputOptions: View {
    @Bindable var speech: ReaderSpeech
    var expandedPicker: Binding<String?>?
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        SpeechOptionPicker(title: "语音引擎", id: "speechEngine", selection: $speech.engine,
                           choices: ReaderSpeech.Engine.allCases.map { ($0, $0.title) }, expandedPicker: expandedPicker)
        if speech.engine == .mac {
            SpeechOptionPicker(title: "Mac 英语声音", id: "speechMacVoice", selection: $speech.macVoice,
                               choices: macVoiceChoices, expandedPicker: expandedPicker)
        } else if KokoroEngine.isInstalled {
            SpeechOptionPicker(title: "Kokoro 英语声音", id: "speechKokoroVoice", selection: $speech.kokoroVoice,
                               choices: [("af_heart", "Heart · 美音女声"), ("am_michael", "Michael · 美音男声"),
                                         ("bf_emma", "Emma · 英音女声"), ("bm_george", "George · 英音男声")],
                               expandedPicker: expandedPicker)
        } else {
            Text("Kokoro 尚未安装，可先用 Mac 内建语音")
                .font(expandedPicker == nil ? .body : .system(size: 15 * scale))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var macVoiceChoices: [(String, String)] {
        var choices = [("", "自动（优先高质量美音）")]
        if !speech.macVoice.isEmpty, !speech.macVoices.contains(where: { $0.identifier == speech.macVoice }) {
            choices.append((speech.macVoice, "上次选择（当前不可用）"))
        }
        return choices + speech.macVoices.map { voice in
            let quality = voice.quality == .premium ? " · 高级" : voice.quality == .enhanced ? " · 增强" : ""
            return (voice.identifier, "\(voice.name) · \(voice.language)\(quality)")
        }
    }
}

private struct SpeechOptionPicker<Value: Hashable>: View {
    let title: String
    let id: String
    @Binding var selection: Value
    let choices: [(value: Value, title: String)]
    let expandedPicker: Binding<String?>?
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        if let expandedPicker {
            let isExpanded = expandedPicker.wrappedValue == id
            let selected = choices.first { $0.value == selection }?.title ?? title
            Button {
                expandedPicker.wrappedValue = isExpanded ? nil : id
            } label: {
                HStack(spacing: 8 * scale) {
                    VStack(alignment: .leading, spacing: 3 * scale) {
                        Text(title)
                        Text(selected)
                            .font(.system(size: 15 * scale))
                            .foregroundStyle(ReaderPalette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").imageScale(.small)
                }
                .padding(.vertical, 5 * scale)
            }
            .buttonStyle(ReaderButtonStyle(prominent: isExpanded, compact: true, scale: 1.55))
            .accessibilityLabel(title)
            .accessibilityValue(selected)
            .accessibilityIdentifier(id)
            if isExpanded {
                ScrollView {
                    VStack(spacing: 4 * scale) {
                        ForEach(choices, id: \.value) { choice in
                            Button {
                                selection = choice.value
                                expandedPicker.wrappedValue = nil
                            } label: {
                                Text(choice.title).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(ReaderButtonStyle(prominent: choice.value == selection,
                                                           compact: true, scale: 1.4))
                            .accessibilityAddTraits(choice.value == selection ? .isSelected : [])
                        }
                    }
                }
                .frame(height: CGFloat(min(3, choices.count)) * 51 * scale)
            }
        } else {
            Picker(title, selection: $selection) {
                ForEach(choices, id: \.value) { choice in Text(choice.title).tag(choice.value) }
            }
            .accessibilityIdentifier(id)
        }
    }
}

struct SpeechPlayerBar: View {
    let speech: ReaderSpeech

    var body: some View {
        let previous: (() -> Void)? = speech.hasPrevious ? { speech.move(-1) } : nil
        let next: (() -> Void)? = speech.hasNext ? { speech.move(1) } : nil
        return ReaderPlaybackBar(
            idPrefix: "speech", isPlaying: speech.isActive, status: speech.error ?? status, hasError: speech.error != nil,
            previous: previous, toggle: { speech.toggle() }, next: next,
            replay: { speech.replay() }, close: { speech.stop() }
        ) {
            EmptyView()
        } accessory: {
            PlaybackSpeedMenu(
                selection: speech.playbackSpeed, onSelect: speech.setPlaybackSpeed,
                id: "speechPlaybackSpeed",
                help: speech.engine == .mac ? "调整朗读速度，从下一句或重听时生效" : "调整朗读速度，即时生效"
            )
        }
    }

    private var status: String {
        let location = "第 \(speech.index + 1)/\(speech.count) 句"
        let state: String
        switch speech.phase {
        case .positioning: state = "定位正文"
        case .loading: state = "准备语音"
        case .playing: state = "朗读中"
        case .paused:
            if speech.waitingForNext { state = speech.hasNext ? "可跟读 · 等待下一句" : "末句已读完 · 可跟读" }
            else { state = "已暂停" }
        case .ready: state = "可重听"
        }
        return "\(speech.engine.title) · \(location) · \(state)"
    }
}

struct PlaybackSpeedMenu: View {
    let selection: Float
    let speeds: [Float]
    let onSelect: (Float) -> Void
    let id: String
    let help: String
    @Environment(\.readerInterfaceScale) private var scale
    @State private var isPresented = false

    init(selection: PlaybackSpeed, onSelect: @escaping (PlaybackSpeed) -> Void, id: String, help: String) {
        self.init(rate: selection.rawValue, speeds: PlaybackSpeed.allCases.map(\.rawValue), onSelect: { rate in
            if let speed = PlaybackSpeed(rawValue: rate) { onSelect(speed) }
        }, id: id, help: help)
    }

    init(rate: Float, speeds: [Float], onSelect: @escaping (Float) -> Void, id: String, help: String) {
        selection = rate
        self.speeds = speeds
        self.onSelect = onSelect
        self.id = id
        self.help = help
    }

    private func title(_ rate: Float) -> String {
        PlaybackSpeed(rawValue: rate)?.title ?? "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8 * scale) {
                Label(selection == 1 ? "1×" : title(selection), systemImage: "speedometer")
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .fixedSize()
        }
        .buttonStyle(ReaderButtonStyle(prominent: isPresented, compact: true, scale: 2))
        .accessibilityLabel("播放倍速")
        .accessibilityValue(title(selection))
        .accessibilityIdentifier(id)
        .help(help)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(spacing: 6 * scale) {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        onSelect(speed)
                        isPresented = false
                    } label: {
                        HStack(spacing: 10 * scale) {
                            Text(title(speed))
                            Spacer(minLength: 0)
                            if speed == selection { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .frame(width: 168 * scale)
                    }
                    .buttonStyle(ReaderButtonStyle(prominent: speed == selection, compact: true, scale: 2))
                    .accessibilityAddTraits(speed == selection ? .isSelected : [])
                }
            }
            .padding(10 * scale)
            .background(ReaderPalette.chrome)
            .environment(\.readerInterfaceScale, scale)
        }
    }
}

struct ReaderPlaybackBar<Progress: View, Accessory: View>: View {
    let idPrefix: String
    let isPlaying: Bool
    let status: String
    var hasError = false
    let previous: (() -> Void)?
    let toggle: () -> Void
    let next: (() -> Void)?
    let replay: (() -> Void)?
    var close: (() -> Void)?
    var extraShortcut: ((NSEvent) -> (() -> Void)?)?
    @ViewBuilder var progress: Progress
    @ViewBuilder var accessory: Accessory
    @Environment(\.readerInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * interfaceScale) {
            progress
            transport
        }
        .padding(.horizontal, 20 * interfaceScale)
        .padding(.vertical, 12 * interfaceScale)
        .background(ReaderPalette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(ReaderPalette.rule).frame(height: 1) }
        .background(PlaybackShortcutMonitor(action: shortcutAction, extraAction: extraShortcut))
    }

    private func shortcutAction(_ shortcut: PlaybackShortcut) -> (() -> Void)? {
        switch shortcut {
        case .previous: previous
        case .toggle: toggle
        case .next: next
        case .replay: replay
        }
    }

    private var transport: some View {
        ViewThatFits(in: .horizontal) {
            playerRow(showStatus: true)
            VStack(alignment: .leading, spacing: 8) {
                statusLabel
                playerRow(showStatus: false)
            }
        }
    }

    private func playerRow(showStatus: Bool) -> some View {
        HStack(spacing: 12 * interfaceScale) {
            icon("上一句", "backward.end.fill", id: "Previous", shortcut: .previous, action: previous)
            icon(isPlaying ? "暂停播放" : "播放", isPlaying ? "pause.fill" : "play.fill",
                 id: "Toggle", prominent: true, shortcut: .toggle, action: toggle)
            icon("下一句", "forward.end.fill", id: "Next", shortcut: .next, action: next)
            icon("重听", "arrow.counterclockwise", id: "Replay", shortcut: .replay, action: replay)
            if showStatus { statusLabel.fixedSize(horizontal: true, vertical: false) }
            accessory
            Spacer(minLength: 0)
            if let close { icon("关闭播放器", "xmark", id: "Close", action: close) }
        }
    }

    private var statusLabel: some View {
        Text(status)
            .font(.system(size: 24 * interfaceScale))
            .foregroundStyle(hasError ? ReaderPalette.warning : ReaderPalette.muted)
            .lineLimit(2)
            .accessibilityIdentifier(idPrefix + "Status")
    }

    private func icon(_ title: String, _ symbol: String, id: String, prominent: Bool = false,
                      shortcut: PlaybackShortcut? = nil, action: (() -> Void)?) -> some View {
        Button { action?() } label: { Image(systemName: symbol).frame(width: 40 * interfaceScale) }
            .buttonStyle(ReaderButtonStyle(prominent: prominent, compact: true, scale: 2, primary: prominent))
            .accessibilityLabel(title)
            .accessibilityIdentifier(idPrefix + id)
            .help(shortcut.map { "\(title)（\($0.hint)）" } ?? title)
            .disabled(action == nil)
    }
}
