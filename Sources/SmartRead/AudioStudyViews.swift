import SwiftUI

func audioTimeText(_ seconds: Double) -> String {
    let seconds = Int(max(seconds, 0))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct AudioStudyInspector: View {
    let model: AudioStudyModel
    let assistant: AudioSubtitleAssistant
    let reader: ReaderModel
    let fontSize: Double
    @Binding var showsSubtitles: Bool
    @Binding var clickWholeSentence: Bool
    let edit: (AudioStudyCue) -> Void
    let locateQuestionSource: (AssistantQuestionReference, NSRange?) async throws -> Void

    var body: some View {
        AssistantInspector(reader: reader, mode: .audio, materialID: model.entry?.id.uuidString,
                           locate: locateQuestionSource, manualSelection: showsSubtitles ? model.questionSelection : nil,
                           visiblePassage: showsSubtitles ? assistant.selection?.sentence.text : nil,
                           sentenceFavorite: sentenceFavorite, reference: questionReference) {
            Button(showsSubtitles ? "隐藏字幕" : "显示字幕") { showsSubtitles.toggle() }
                .disabled(model.cues.isEmpty)
                .accessibilityIdentifier("audioShowSubtitles")
            Toggle("点整句", isOn: $clickWholeSentence)
            Button("修正当前句") { if let editableCue { edit(editableCue) } }
                .disabled(!showsSubtitles || editableCue == nil)
                .accessibilityIdentifier("editFocusedAudioCue")
            if showsSubtitles, let target {
                Button("翻译当前句") {
                    if model.isPlaying { model.pause() }
                    if let entry = model.entry,
                       let sentence = AudioSubtitleSelection(entry: entry, cueID: target.cueID,
                           target: target.word.map { SubtitleWord(text: $0.text, range: $0.range) }, wholeSentence: true) {
                        model.selectQuestionReference(sentence)
                        assistant.select(sentence, using: reader)
                    }
                }
                if assistant.selection?.word != nil {
                    Button(StudyKind.phrase.label) { assistant.showPhrase(using: reader) }
                }
                Button("回到原文") { model.locateCue(target.cueID) }
                    .accessibilityIdentifier("assistantReturnToSource")
            }
            if let translation = assistant.translation.result.completedText, showsSubtitles {
                Button("复制译文") { copyAssistantResult(translation) }
            }
        } content: {
            if showsSubtitles, let selection = assistant.selection {
                results(selection)
            } else {
                Text(!showsSubtitles ? "字幕已隐藏。"
                     : model.cues.isEmpty ? "导入音频后，英文字幕由本机转写。"
                     : "点击字幕查看词义和整句翻译。")
                    .font(.system(size: 13))
                    .foregroundStyle(ReaderPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
    }

    private var sentenceFavorite: AssistantSentenceFavoriteAction? {
        guard showsSubtitles, let entry = model.entry, let selection = assistant.selection,
              let cue = model.cues.first(where: { $0.id == selection.cueID }),
              let reference = selection.questionReference(in: entry) else { return nil }
        return .init(marks: reader.listeningMarks,
                     target: .init(reference: reference, milliseconds: Int64((cue.start * 1000).rounded())))
    }

    private var resultFontSize: Double { max(15, min(28, fontSize * 0.72)) }

    private func results(_ selection: AudioSubtitleSelection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let word = selection.word {
                AssistantSectionTitle(title: "词义")
                Text(word.text).font(.system(size: 25, weight: .semibold, design: .serif)).textSelection(.enabled)
                AssistantResult(result: assistant.word.result, fontSize: resultFontSize, cancel: assistant.word.cancel) {
                    assistant.retryWord(using: reader)
                }
                Divider()
            }
            let cue = model.cues.first { $0.id == selection.cueID }
            AssistantPassage(sentence: selection.sentence.text, focus: selection.word?.contextWordRange,
                             timestamp: cue.map { audioTimeText($0.start) })
            AssistantResult(result: assistant.translation.result, fontSize: resultFontSize,
                            cancel: assistant.translation.cancel) { assistant.translate(using: reader) }
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                AssistantGrammarRow(isExpanded: assistant.grammarExpanded) { assistant.toggleGrammar(using: reader) }
                if assistant.grammarExpanded {
                    AssistantResult(result: assistant.grammar.result, fontSize: resultFontSize,
                                    cancel: assistant.grammar.cancel) { assistant.analyze(using: reader) }
                        .padding(.bottom, 12)
                }
                Divider()
            }
            if case .idle = assistant.phrase {
                EmptyView()
            } else {
                HStack {
                    AssistantSectionTitle(title: "搭配")
                    Spacer()
                    Button("收起", action: assistant.hidePhrase).buttonStyle(.link)
                }
                AssistantResult(result: assistant.phrase, fontSize: resultFontSize) { assistant.showPhrase(using: reader) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private func questionReference(currentOnly: Bool) -> AssistantQuestionReference? {
        guard showsSubtitles, let entry = model.entry else { return nil }
        let focused = model.focusedCueIndex.map { model.cues[$0] }
        let target = currentOnly ? assistant.selection.flatMap { $0.cueID == focused?.id ? $0 : nil } : assistant.selection
        let reference = target ?? focused.flatMap { AudioSubtitleSelection(entry: entry, cueID: $0.id) }
        return reference?.questionReference(in: entry)
    }

    private var editableCue: AudioStudyCue? {
        if let id = assistant.selection?.cueID, let cue = model.cues.first(where: { $0.id == id }) { return cue }
        return model.focusedCueIndex.map { model.cues[$0] }
    }

    private var target: AudioSubtitleSelection? {
        guard let entry = model.entry else { return nil }
        return assistant.selection ?? editableCue.flatMap { AudioSubtitleSelection(entry: entry, cueID: $0.id) }
    }
}

struct AudioPlayerBar: View {
    let model: AudioStudyModel
    var captureMark: (() -> (() -> Void)?)? = nil
    var trackedReplay: (() -> Void)? = nil
    @State private var scrubPosition: Double?
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        let previous: (() -> Void)? = model.canMoveCue(by: -1) ? { model.moveCue(by: -1) } : nil
        let next: (() -> Void)? = model.canMoveCue(by: 1) ? { model.moveCue(by: 1) } : nil
        let replay: (() -> Void)? = model.canReplay ? trackedReplay ?? { model.replay() } : nil
        let speedMenu = PlaybackSpeedMenu(
            selection: Binding(get: { model.playbackSpeed }, set: model.setPlaybackSpeed),
            id: "audioPlaybackSpeed", help: "即时生效"
        )
        return ReaderPlaybackBar(
            idPrefix: "audio", isPlaying: model.isPlaying, status: status,
            previous: previous, toggle: { model.togglePlayback() }, next: next, replay: replay,
            speedMenu: speedMenu, captureMark: captureMark
        ) {
            HStack(spacing: 12) {
                Text(audioTimeText(scrubPosition ?? model.position))
                Slider(value: Binding(
                    get: { scrubPosition ?? model.position },
                    set: { if scrubPosition == nil { model.seek(to: $0) } else { scrubPosition = $0 } }
                ), in: 0...max(model.duration, 0.01)) {
                    Text("播放进度")
                } onEditingChanged: { editing in
                    if editing {
                        scrubPosition = model.position
                    } else if let scrubPosition {
                        model.seek(to: scrubPosition)
                        self.scrubPosition = nil
                    }
                }
                .labelsHidden()
                .controlSize(.large)
                .accessibilityIdentifier("audioProgressSlider")
                Text(audioTimeText(model.duration))
            }
            .font(.system(size: max(12, 15 * scale)).monospacedDigit())
            .foregroundStyle(ReaderPalette.muted)
            .onChange(of: model.entry?.id) { scrubPosition = nil }
        } accessory: {
            EmptyView()
        }
    }

    private var status: String {
        var parts = ["原声"]
        if let index = model.focusedCueIndex { parts.append("第 \(index + 1)/\(model.cues.count) 句") }
        if model.waitingForNext {
            parts.append(model.canMoveCue(by: 1) ? "可跟读 · 等待下一句" : "末句已播完 · 可跟读")
        } else {
            parts.append(model.isPlaying ? "播放中" : "已暂停")
        }
        return parts.joined(separator: " · ")
    }
}

struct AudioHistorySheet: View {
    let model: AudioStudyModel
    @State private var fixing = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("音频历史")
                .font(.system(size: 25, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let problem { Text(problem).foregroundStyle(ReaderPalette.warning) }
            ForEach(model.unreadableRecords, id: \.self) { file in
                HStack {
                    Text("记录无法读取 · " + file.deletingLastPathComponent().lastPathComponent)
                    Button("查看文件") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
            if model.history.isEmpty && model.unreadableRecords.isEmpty {
                ContentUnavailableView("暂无历史音频", systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.history) { entry in
                            Button {
                                if model.hasMedia(entry) {
                                    model.open(entry.id)
                                    dismiss()
                                } else {
                                    let panel = NSOpenPanel()
                                    panel.title = "选择原音频以恢复字幕和进度"
                                    panel.allowedContentTypes = AudioStudyFormat.contentTypes
                                    guard panel.runModal() == .OK, let url = panel.url else { return }
                                    fixing = true
                                    Task {
                                        defer { fixing = false }
                                        do { try await model.relink(url, to: entry); dismiss() }
                                        catch { problem = error.localizedDescription }
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "waveform").foregroundStyle(ReaderPalette.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.title).font(.system(size: 17, weight: .medium)).lineLimit(2)
                                        Text(entry.format.rawValue.uppercased() + " · " + audioTimeText(entry.position)
                                             + " / " + audioTimeText(entry.duration))
                                            .font(.system(size: 12))
                                            .foregroundStyle(ReaderPalette.muted)
                                    }
                                    Spacer(minLength: 0)
                                    if !model.hasMedia(entry) {
                                        Text("音频文件缺失 · 重新关联").foregroundStyle(ReaderPalette.warning)
                                    } else if entry.id == model.entry?.id {
                                        Image(systemName: "checkmark").foregroundStyle(ReaderPalette.accent)
                                    }
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 9))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9).strokeBorder(ReaderPalette.rule)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .disabled(fixing)
                .accessibilityIdentifier("audioHistoryList")
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
        .padding(23)
        .frame(width: 620, height: 430)
        .background(ReaderPalette.panel)
        .foregroundStyle(ReaderPalette.ink)
        .tint(ReaderPalette.primaryButton)
    }
}

struct AudioStudyContent: View {
    let model: AudioStudyModel
    let fontSize: Double
    let showsSubtitles: Bool
    let maskOpacity: Double
    let highlightsSentence: Bool
    let selection: AudioSubtitleSelection?
    var markedCues: Set<UUID> = []
    let lookUp: (UUID, SubtitleWord) -> Void
    let edit: (AudioStudyCue) -> Void
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            if let entry = model.entry {
                mediaHeading(entry)
                Rectangle().fill(ReaderPalette.rule).frame(height: 1)
                transcript
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderPalette.paper)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if model.isImporting {
                ProgressView()
                Text("正在导入…")
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 43, weight: .medium))
                    .foregroundStyle(ReaderPalette.accent)
                    .accessibilityHidden(true)
                Text("将 MP3 或 MP4 拖到这里")
                    .font(.system(size: 24, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mediaHeading(_ entry: AudioStudyEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.system(size: min(42, max(32, fontSize + 8)), design: .serif))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("audioEntryTitle")
            Text(entry.format.rawValue.uppercased() + " · " + audioTimeText(entry.duration))
                .font(.system(size: 13))
                .foregroundStyle(ReaderPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 31)
        .padding(.bottom, 13)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let status = model.transcriptionStatus {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(status)
                    }
                    .foregroundStyle(ReaderPalette.muted)
                    .accessibilityIdentifier("audioTranscriptionStatus")
                    .padding(28)
                    .frame(maxWidth: .infinity)
                } else if let error = model.transcriptionError {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                            .accessibilityIdentifier("audioTranscriptionError")
                        if AudioStudyTranscriber.isAvailable {
                            Button("重新生成字幕") { model.transcribe() }
                                .buttonStyle(ReaderButtonStyle(prominent: true))
                        }
                    }
                    .foregroundStyle(ReaderPalette.muted)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.cues.enumerated()), id: \.element.id) { index, cue in
                            cueRow(cue, index: index)
                                .id(cue.id)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: model.focusedCueID, initial: true) { _, id in
                if let id {
                    withAnimation(.easeInOut(duration: 0.32)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onChange(of: model.sourceJump) { _, jump in
                if let jump {
                    withAnimation(.easeInOut(duration: 0.32)) { proxy.scrollTo(jump.cueID, anchor: .center) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func cueRow(_ cue: AudioStudyCue, index: Int) -> some View {
        let active = cue.id == model.focusedCueID
        let highlighted = active && highlightsSentence
        let selectedWord = selection?.cueID == cue.id
            ? selection?.word.map { SubtitleWord(text: $0.text, range: $0.range) } : nil
        let shaded = model.focusedCueID != nil && (model.isPlaying || model.waitingForNext) && !active && selectedWord == nil
        let tone = ReaderPalette.highlight(.spoken)
        let ink = highlighted ? Color(nsColor: tone.ink) : ReaderPalette.ink
        return HStack(spacing: 12) {
            Button { model.playCue(cue.id) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: max(11, 12 * scale)))
                    Text(audioTimeText(cue.start))
                        .font(.system(size: max(12, 14 * scale)).monospacedDigit())
                }
                .fixedSize()
                .padding(.horizontal, 6 * scale)
                .frame(minWidth: 62 * scale, minHeight: 38 * scale)
                .foregroundStyle(ReaderPalette.accent)
                .background(ReaderPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityLabel("播放第 \(index + 1) 句原声")
            .accessibilityValue(audioTimeText(cue.start))
            .accessibilityIdentifier("audioCue-\(index + 1)")
            .help("播放这一句原声")

            Group {
                if showsSubtitles {
                    ClickableSubtitleText(text: cue.text, fontSize: fontSize, selectedWord: selectedWord,
                                          contentIdentity: cue.id.uuidString,
                                          alignment: .left, usesSerif: true,
                                          foreground: highlighted ? tone.ink : ReaderPalette.inkNS,
                                          listeningMarks: markedCues.contains(cue.id) ? [NSRange(location: 0, length: cue.text.utf16.count)] : [],
                                          onSelectionBegan: { if model.isPlaying { model.pause() } }) { word, _ in
                        lookUp(cue.id, word)
                    }
                } else {
                    Text("第 \(index + 1) 句")
                }
            }
            .font(.system(size: fontSize, design: showsSubtitles ? .serif : .default))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("audioCueText-\(index + 1)")

            if showsSubtitles {
                Button { edit(cue) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: max(13, 16 * scale)))
                        .frame(width: 36 * scale, height: 38 * scale)
                        .foregroundStyle(highlighted ? Color(nsColor: tone.ink) : ReaderPalette.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("修正第 \(index + 1) 句")
                .accessibilityIdentifier("editAudioCue-\(index + 1)")
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(highlighted ? Color(nsColor: tone.fill) : ReaderPalette.card,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(ReaderPalette.rule, lineWidth: highlighted ? 0 : 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if shaded, maskOpacity > 0 {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(maskOpacity))
                    .allowsHitTesting(false)
            }
        }
    }

}

struct AudioCueEditor: View {
    let cue: AudioStudyCue
    let save: (AudioStudyCue) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var start = ""
    @State private var end = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修正字幕")
                .font(.title2.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(size: 18))
                .frame(height: 95)
                .border(ReaderPalette.rule)
                .accessibilityLabel("字幕文字")
                .accessibilityIdentifier("audioCueText")
            HStack(spacing: 18) {
                TextField("起点（秒）", text: $start).accessibilityIdentifier("audioCueStart")
                TextField("终点（秒）", text: $end).accessibilityIdentifier("audioCueEnd")
            }
            .textFieldStyle(.roundedBorder)
            if let problem {
                Text(problem).foregroundStyle(ReaderPalette.warning)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("saveAudioCue")
            }
        }
        .padding(22)
        .frame(width: 490)
        .onAppear {
            text = cue.text
            start = String(cue.start)
            end = String(cue.end)
        }
    }

    private func submit() {
        guard let start = Double(start.trimmingCharacters(in: .whitespaces)),
              let end = Double(end.trimmingCharacters(in: .whitespaces)) else {
            problem = "请输入秒数，例如 19.44。"
            return
        }
        do {
            try save(AudioStudyCue(id: cue.id, start: start, end: end, text: text))
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
