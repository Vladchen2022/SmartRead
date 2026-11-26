import SwiftUI

struct VideoStudyInspector: View {
    @ObservedObject var model: VideoStudyModel
    let reader: ReaderModel
    let locateQuestionSource: (AssistantQuestionReference, NSRange?) async throws -> Void
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        ReaderInspector(scrollsContent: model.sidebarMode != .transcript) {
            VStack(alignment: .leading, spacing: 12 * scale) {
                ReaderInspectorHeading(title: "学习助手", symbol: "text.bubble")
                AssistantActions(selected: selectedAction, available: availableActions, perform: perform)
                VideoStudyTools(model: model)
            }
        } content: {
            switch model.sidebarMode {
            case .analysis:
                AnalysisDetailView(model: model)
            case .word:
                WordExplanationView(model: model)
            case .phrase:
                if let request = model.assistantPhraseRequest {
                    VideoPhraseView(model: model, reader: reader, request: request).id(request)
                }
            case .transcript:
                SubtitleTranscriptView(model: model)
            }
        } footer: {
            if (model.sidebarMode == .word || model.sidebarMode == .analysis), !model.obsidianVaultPath.isEmpty {
                Divider()
                ObsidianConfirmationFooter(model: model)
            }
            AssistantQuestionPanel(reader: reader, mode: .video, materialID: model.currentSourceVideoURL?.absoluteString,
                                   locate: locateQuestionSource, manualSelection: model.questionSelection,
                                   reference: model.questionReference)
        }
    }

    private var selectedAction: AssistantAction? {
        switch model.sidebarMode {
        case .analysis: model.selectedSubtitle == nil ? nil : .sentence
        case .word: .word
        case .phrase: .phrase
        case .transcript: nil
        }
    }

    private var availableActions: Set<AssistantAction> {
        var actions: Set<AssistantAction> = []
        if model.hasAssistantWord { actions.insert(.word) }
        if model.assistantPhraseRequest != nil { actions.insert(.phrase) }
        if model.canAnalyzeAssistantSentence { actions.insert(.sentence) }
        return actions
    }

    private func perform(_ action: AssistantAction) {
        switch action {
        case .word:
            model.pauseForLearning()
            model.sidebarMode = .word
        case .phrase:
            model.pauseForLearning()
            model.sidebarMode = .phrase
        case .sentence:
            model.analyzeAssistantSentence()
        }
    }
}

private struct VideoAssistantSource: View {
    @ObservedObject var model: VideoStudyModel
    let sentence: String

    var body: some View {
        if let source = model.sidebarSource {
            AssistantSourceRow(sentence: source.sentence, timestamp: SubtitleTimeLabel.string(source.time),
                               goBack: model.jumpToSidebarSource)
        } else {
            Text(sentence)
                .textSelection(.enabled)
        }
    }
}

private struct VideoPhraseView: View {
    @ObservedObject var model: VideoStudyModel
    let reader: ReaderModel
    let request: StudyRequest
    @State private var result: AssistantLookupResult = .loading("")
    @State private var retry = 0
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoAssistantSource(model: model, sentence: request.target.text)
            Divider()
            AssistantResult(result: result, fontSize: 19 * scale) { retry += 1 }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: retry) {
            result = .loading("")
            do {
                let study = try await reader.fetchLanguageStudy(request)
                try Task.checkCancellation()
                result = .phrase(study)
            } catch {
                guard !Task.isCancelled else { return }
                result = .failed(ReaderModel.connectionMessage(error))
            }
        }
    }
}

private struct ObsidianConfirmationFooter: View {
    @ObservedObject var model: VideoStudyModel

    private var title: String {
        switch model.currentNoteState {
        case .idle: "添加到 Obsidian"
        case .writing: "正在写入…"
        case .saved: "已添加到 Obsidian"
        case .pending: "重试写入"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: model.confirmCurrentNote) {
                Label(title, systemImage: model.currentNoteState.isSaved ? "checkmark.circle" : "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ReaderButtonStyle(prominent: true, compact: true, scale: 1.3))
            .disabled(!model.canConfirmCurrentNote)
            .accessibilityIdentifier("confirmObsidianNote")
            Group {
                if model.obsidianVaultPath.isEmpty {
                    Text("请先在设置中选择 Obsidian 文件夹。")
                } else {
                    switch model.currentNoteState {
                    case .idle: Text("确认后才写入；未确认的查询不会收录。")
                    case .writing: Text("正在更新当天的同一篇笔记。")
                    case let .saved(note): Text("已写入 \(note)。")
                    case let .pending(message): Text(message)
                    }
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension NoteConfirmationState {
    var isSaved: Bool { if case .saved = self { true } else { false } }
}

private struct WordExplanationView: View {
    @ObservedObject var model: VideoStudyModel
    @Environment(\.readerInterfaceScale) private var scale
    private var fontSize: CGFloat { 19 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let request = model.selectedWordRequest {
                Text(request.word.text)
                    .font(.system(size: fontSize + 8, weight: .semibold))
                    .textSelection(.enabled)
                VideoAssistantSource(model: model, sentence: request.sentence)
                Divider()
                switch model.wordLookupState {
                case .idle:
                    EmptyView()
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在查询词语…")
                            .font(.system(size: fontSize))
                            .foregroundStyle(.secondary)
                        Button("取消") { model.cancelWordLookup() }
                    }
                case let .loaded(explanation):
                    AnalysisSection(title: "原形 · 词性", content: "\(explanation.lemma) · \(explanation.partOfSpeechZh)", fontSize: fontSize)
                    AnalysisSection(title: "本句中的意思", content: explanation.meaningZh, fontSize: fontSize)
                    AnalysisSection(title: "用法", content: explanation.usageNoteZh, fontSize: fontSize)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("例句")
                            .font(.system(size: max(13, fontSize - 3), weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(explanation.exampleEnglish)
                            .font(.system(size: fontSize + 1, weight: .semibold))
                            .textSelection(.enabled)
                        Text(explanation.exampleChinese)
                            .font(.system(size: fontSize))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: fontSize))
                        .foregroundStyle(ReaderPalette.warning)
                    Button("重试查词") { model.retryWordLookup() }
                }
            } else {
                ContentUnavailableView(
                    "点词或拖选短语", systemImage: "character.book.closed",
                    description: Text("点击单词，或从第一个词拖到最后一个词（最多八个词）。视频会暂停，解释只针对选中的词语。")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnalysisDetailView: View {
    @ObservedObject var model: VideoStudyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let selection = model.selectedSubtitle {
                VideoAssistantSource(model: model, sentence: selection.english)
                if !selection.chinese.isEmpty {
                    Text(selection.chinese)
                        .font(.system(size: analysisFontSize))
                        .foregroundStyle(ReaderPalette.muted)
                        .textSelection(.enabled)
                }

                Divider()

                analysisContent
            } else {
                ContentUnavailableView(
                    "点击「整句解析」",
                    systemImage: "text.bubble",
                    description: Text("视频会暂停，当前句子的本地 AI 解释会显示在这里。")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var analysisContent: some View {
        switch model.analysisState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在解析字幕…")
                    .font(.system(size: analysisFontSize))
                    .foregroundStyle(.secondary)
                Button("取消") { model.cancelAnalysis() }
            }
        case let .loaded(analysis):
            VStack(alignment: .leading, spacing: 18) {
                if let source = analysis.analyzedEnglish,
                   SubtitleWordTokenizer.words(in: source).map(\.text) != SubtitleWordTokenizer.words(in: model.selectedSubtitle?.english ?? "").map(\.text) {
                    AnalysisSection(title: model.selectedSubtitle?.sourceContext?.cues.count == 1 ? "实际解析台词" : "结合相邻字幕理解\(model.selectedSubtitle?.sourceContext.map { "（\($0.cues.count) 条）" } ?? "")", content: source, fontSize: analysisFontSize)
                }
                AnalysisSection(
                    title: "意思",
                    content: analysis.translationZh,
                    fontSize: analysisFontSize
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("表达")
                        .font(
                            .system(
                                size: sectionTitleFontSize,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.secondary)
                    Text(analysis.keyExpression)
                        .font(.system(size: analysisFontSize + 1, weight: .semibold))
                        .textSelection(.enabled)
                    Text(analysis.expressionMeaningZh)
                        .font(.system(size: analysisFontSize))
                        .textSelection(.enabled)
                    if !analysis.usageNoteZh.isEmpty {
                        Text(analysis.usageNoteZh)
                            .font(.system(size: max(14, analysisFontSize - 1)))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("例句")
                        .font(
                            .system(
                                size: sectionTitleFontSize,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.secondary)
                    Text(analysis.exampleEnglish)
                        .font(.system(size: analysisFontSize + 1, weight: .semibold))
                        .textSelection(.enabled)
                    Text(analysis.exampleChinese)
                        .font(.system(size: analysisFontSize))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !analysis.similarExpressions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("相近表达")
                            .font(
                                .system(
                                    size: sectionTitleFontSize,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.secondary)

                        ForEach(
                            Array(analysis.similarExpressions.enumerated()),
                            id: \.offset
                        ) { _, expression in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(expression.english)
                                    .font(
                                        .system(
                                            size: analysisFontSize + 1,
                                            weight: .semibold
                                        )
                                    )
                                    .textSelection(.enabled)
                                Text(expression.chinese)
                                    .font(.system(size: analysisFontSize))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: analysisFontSize))
                    .foregroundStyle(ReaderPalette.warning)
                Button("重试") {
                    model.retryAnalysis()
                }
            }
        }
    }

    @Environment(\.readerInterfaceScale) private var scale
    private var analysisFontSize: CGFloat { 19 * scale }

    private var sectionTitleFontSize: CGFloat {
        max(13, analysisFontSize - 3)
    }
}

private struct AnalysisSection: View {
    let title: String
    let content: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: max(13, fontSize - 3), weight: .semibold))
                .foregroundStyle(.secondary)
            Text(content)
                .font(.system(size: fontSize))
                .textSelection(.enabled)
        }
    }
}
