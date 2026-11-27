import SwiftUI

struct VideoStudyInspector: View {
    @ObservedObject var model: VideoStudyModel
    let reader: ReaderModel
    @Binding var clickWholeSentence: Bool
    var listeningMarks: [ListeningMark] = []
    let locateQuestionSource: (AssistantQuestionReference, NSRange?) async throws -> Void
    @State private var translation = AssistantLanguageLookup()
    @State private var showsWordDetails = false
    @State private var showsCalibration = false
    @State private var modeBeforeTranscript: SidebarMode = .analysis
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        AssistantInspector(reader: reader, mode: .video, materialID: model.currentSourceVideoURL?.absoluteString,
                           locate: locateQuestionSource, manualSelection: model.questionSelection,
                           visiblePassage: visiblePassage, scrollsContent: model.sidebarMode != .transcript,
                           sentenceFavorite: sentenceFavorite, reference: model.questionReference) {
            tools
        } content: {
            switch model.sidebarMode {
            case .analysis, .word:
                if let selection = model.selectedSubtitle, let source = model.sidebarSource, model.showEnglishSubtitle {
                    results(selection, time: source.time)
                } else {
                    Text(model.showEnglishSubtitle ? "点击英文字幕查看词义和整句翻译。" : "字幕已隐藏。")
                        .font(.system(size: 13))
                        .foregroundStyle(ReaderPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            case .phrase:
                if let request = model.assistantPhraseRequest {
                    VideoPhraseView(reader: reader, request: request).id(request)
                }
            case .transcript:
                SubtitleTranscriptView(model: model, listeningMarks: listeningMarks)
            }
        }
        .onChange(of: model.selectedSubtitle, initial: true) { updateTranslation() }
        .onChange(of: model.showEnglishSubtitle) { updateTranslation() }
        .onChange(of: model.selectedWordRequest) { showsWordDetails = false }
        .onDisappear { translation.clear() }
        .sheet(isPresented: $showsCalibration) {
            VideoSubtitleCalibration(model: model, isPresented: $showsCalibration)
        }
    }

    private var visiblePassage: String? {
        guard model.showEnglishSubtitle, model.sidebarMode == .analysis || model.sidebarMode == .word,
              model.sidebarSource != nil else { return nil }
        return model.selectedSubtitle?.english
    }

    private var sentenceFavorite: AssistantSentenceFavoriteAction? {
        guard visiblePassage != nil, let reference = model.questionReference(currentOnly: false),
              let source = model.sidebarSource else { return nil }
        return .init(marks: reader.listeningMarks, target: .init(reference: reference, milliseconds: source.time))
    }

    private func updateTranslation() {
        guard model.showEnglishSubtitle, let selection = model.selectedSubtitle, selection.chinese.isEmpty else {
            translation.clear()
            return
        }
        let excerpt = TextExcerpt(text: selection.english,
                                  range: NSRange(location: 0, length: selection.english.utf16.count), context: selection.english)
        translation.load(.init(kind: .translation, excerpt: excerpt,
                               surrounding: SentenceContext(previousSentence: selection.previousEnglish,
                                                            nextSentence: selection.nextEnglish)), using: reader)
    }

    @ViewBuilder
    private var tools: some View {
        Toggle("点整句", isOn: $clickWholeSentence)
        Button("翻译当前句", action: model.translateCurrentSubtitle)
            .disabled(!model.showEnglishSubtitle || !model.canAnalyzeCurrentSubtitle)
        if model.showEnglishSubtitle, model.sidebarSource != nil, model.sidebarMode != .transcript {
            Button("回到原文", action: model.jumpToSidebarSource)
                .accessibilityIdentifier("assistantReturnToSource")
        }
        if model.showEnglishSubtitle, model.sidebarMode == .word || model.sidebarMode == .phrase {
            if model.sidebarMode == .phrase {
                Button("返回词义和译文") { model.sidebarMode = .word }
            } else {
                Button(showsWordDetails ? "收起用法和例句" : "用法和例句") { showsWordDetails.toggle() }
                if model.assistantPhraseRequest != nil {
                    Button(StudyKind.phrase.label) { model.pauseForLearning(); model.sidebarMode = .phrase }
                }
            }
        }
        if model.showEnglishSubtitle, let selection = model.selectedSubtitle, model.sidebarMode != .transcript {
            if let text = selection.chinese.isEmpty ? translation.result.completedText : selection.chinese {
                Button("复制译文") { copyAssistantResult(text) }
            }
        }
        if model.isListeningFirst {
            Button(model.revealButtonTitle, action: model.revealSubtitle)
                .disabled(!model.canAdvanceListeningStage)
        }
        Button(model.sidebarMode == .transcript ? "返回学习助手" : "查看文稿") {
            if model.sidebarMode == .transcript {
                model.sidebarMode = modeBeforeTranscript
            } else {
                modeBeforeTranscript = model.sidebarMode
                model.sidebarMode = .transcript
            }
        }
        .disabled(model.currentSourceVideoURL == nil)
        .accessibilityIdentifier("videoTranscript")
        VideoStudyTools(model: model, showsCalibration: $showsCalibration)
    }

    private func noteButton(forWord: Bool) -> some View {
        let type = forWord ? "词义" : "语法解析"
        let state = forWord ? model.wordNoteState : model.sentenceNoteState
        let title = switch state {
        case .idle: "添加\(type)到 Obsidian"
        case .writing: "正在写入\(type)…"
        case .saved: "\(type)已添加到 Obsidian"
        case .pending: "重试写入\(type)"
        }
        return Button(title) { model.confirmNote(forWord: forWord) }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
            .disabled(!model.canConfirmNote(forWord: forWord))
            .accessibilityIdentifier(forWord ? "confirmObsidianWord" : "confirmObsidianNote")
    }

    private func results(_ selection: SubtitleSelection, time: Int64) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sidebarMode == .word, let word = model.selectedWordRequest?.word {
                AssistantSectionTitle(title: "词义")
                Text(word.text).font(.system(size: 25, weight: .semibold, design: .serif)).textSelection(.enabled)
                WordExplanationView(model: model, showsDetails: showsWordDetails)
                if !model.obsidianVaultPath.isEmpty, case .loaded = model.wordLookupState {
                    noteButton(forWord: true)
                }
                Divider()
            }
            AssistantPassage(sentence: selection.english,
                             focus: model.sidebarMode == .word ? model.assistantPhraseRequest?.focusedWord?.range : nil,
                             timestamp: SubtitleTimeLabel.string(time))
            if selection.chinese.isEmpty {
                AssistantResult(result: translation.result, fontSize: max(15, 17 * scale),
                                cancel: translation.cancel, retry: updateTranslation)
            } else {
                Text(selection.chinese).font(.system(size: max(15, 17 * scale))).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                AssistantGrammarRow(isExpanded: model.assistantGrammarExpanded, toggle: model.toggleAssistantGrammar)
                if model.assistantGrammarExpanded {
                    AnalysisDetailView(model: model).padding(.bottom, 12)
                    if !model.obsidianVaultPath.isEmpty, case .loaded = model.analysisState {
                        noteButton(forWord: false).padding(.bottom, 12)
                    }
                }
                Divider()
            }
            if model.sidebarMode == .word, case .pending(let message) = model.wordNoteState {
                Text(message).font(.caption).foregroundStyle(ReaderPalette.warning)
            }
            if case .pending(let message) = model.sentenceNoteState {
                Text(message).font(.caption).foregroundStyle(ReaderPalette.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }
}

private struct VideoPhraseView: View {
    let reader: ReaderModel
    let request: StudyRequest
    @State private var result: AssistantLookupResult = .loading("")
    @State private var retry = 0
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AssistantSectionTitle(title: "搭配")
            Text(request.target.text).font(.system(size: 17, design: .serif)).textSelection(.enabled)
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

private struct WordExplanationView: View {
    @ObservedObject var model: VideoStudyModel
    let showsDetails: Bool
    @Environment(\.readerInterfaceScale) private var scale
    private var fontSize: CGFloat { max(15, 17 * scale) }

    var body: some View {
        switch model.wordLookupState {
        case .idle: EmptyView()
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("正在查询词语…").foregroundStyle(ReaderPalette.muted)
                Button("停止", action: model.cancelWordLookup).buttonStyle(.link)
            }
            .font(.caption)
        case .loaded(let explanation):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(explanation.partOfSpeechZh) · \(explanation.meaningZh)")
                    .font(.system(size: fontSize)).textSelection(.enabled)
                if showsDetails {
                    AnalysisSection(title: "原形与用法", content: "\(explanation.lemma) · \(explanation.usageNoteZh)",
                                    fontSize: fontSize)
                    AnalysisSection(title: "例句", content: "\(explanation.exampleEnglish)\n\(explanation.exampleChinese)",
                                    fontSize: fontSize)
                }
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(ReaderPalette.warning)
            Button("重试查词", action: model.retryWordLookup).buttonStyle(.link)
        }
    }
}

private struct AnalysisDetailView: View {
    @ObservedObject var model: VideoStudyModel

    var body: some View {
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
