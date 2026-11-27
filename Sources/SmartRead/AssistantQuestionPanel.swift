import SwiftUI

@MainActor
struct AssistantSentenceFavoriteAction {
    let kind: LearningFavorite.Kind
    let isSaved: Bool
    let toggle: () async throws -> Void

    init(reader: ReaderModel, excerpt: TextExcerpt) {
        kind = .sentence
        isSaved = reader.isSentenceFavorite(excerpt)
        let version = reader.articleVersion
        toggle = {
            guard reader.articleVersion == version else { return }
            try await reader.toggleSentenceFavorite(excerpt)
        }
    }

    init(marks: ListeningMarks, target: ListeningTarget) {
        kind = .originalSentence
        isSaved = marks.isMediaFavorite(target)
        toggle = { try marks.toggleMediaFavorite(target) }
    }
}

struct AssistantInspector<Tools: View, Content: View>: View {
    let reader: ReaderModel
    let mode: ReaderMode
    let materialID: String?
    let locate: (AssistantQuestionReference, NSRange?) async throws -> Void
    var isActive = true
    let manualSelection: AssistantQuestionSelection?
    var visiblePassage: String? = nil
    var scrollsContent = true
    var sentenceFavorite: AssistantSentenceFavoriteAction? = nil
    let reference: (_ currentOnly: Bool) -> AssistantQuestionReference?
    @ViewBuilder let tools: () -> Tools
    @ViewBuilder let content: () -> Content

    @State private var suppressesAutomaticReference = false
    @State private var referenceMessage: String?
    @State private var sheet: PanelSheet?
    @State private var sentenceFavoriteTask: Task<Void, Never>?
    @FocusState private var focusesDraft: Bool
    @Environment(\.readerInterfaceScale) private var scale

    private var chat: AssistantQuestionChat { reader.questionChat(for: mode) }

    private enum PanelSheet: Identifiable {
        case favorites, practice(AssistantQuestionTurn)

        var id: String {
            switch self {
            case .favorites: "favorites"
            case .practice(let turn): turn.id.uuidString
            }
        }
    }

    var body: some View {
        ReaderInspector(scrollsContent: scrollsContent) {
            HStack {
                Text("学习助手")
                    .font(.system(size: max(15, 18 * scale), weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4 * scale)
                if let sentenceFavorite { sentenceFavoriteButton(sentenceFavorite) }
                Menu {
                    tools()
                    Divider()
                    Menu("问 AI") { questionTools }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16 * scale, weight: .semibold))
                        .frame(minWidth: 30, minHeight: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多工具")
                .accessibilityIdentifier("studyMenu")
            }
        } content: {
            content()
        } footer: {
            Divider()
            VStack(alignment: .leading, spacing: 8 * scale) {
                Text("问 AI").font(.system(size: 17 * scale, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let quote = chat.reference, quote.passage != visiblePassage {
                    Text("引用 · \(quote.passage)")
                        .font(.system(size: 14 * scale))
                        .foregroundStyle(ReaderPalette.muted)
                        .lineLimit(1)
                        .help(quote.passage)
                        .accessibilityIdentifier("assistantQuestionPassage")
                }
                if let referenceMessage {
                    Text(referenceMessage).font(.system(size: 14 * scale)).foregroundStyle(ReaderPalette.muted)
                }
                transcript
                composer
            }
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 11 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: focusesDraft) { _, focused in
            if focused { seedReference() }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                chat.stop()
                focusesDraft = false
                sentenceFavoriteTask?.cancel()
            }
        }
        .onChange(of: materialID, initial: true) { _, material in
            sentenceFavoriteTask?.cancel()
            chat.activate(material: material)
            suppressesAutomaticReference = false
            referenceMessage = nil
        }
        .onChange(of: manualSelection, initial: true) { _, selection in
            guard let selection else { return }
            chat.selectReference(selection)
            suppressesAutomaticReference = false
            referenceMessage = nil
        }
        .onDisappear {
            chat.stop()
            sentenceFavoriteTask?.cancel()
        }
        .sheet(item: $sheet) { selection in
            switch selection {
            case .favorites: AssistantQuestionFavoritesSheet(favorites: reader.questionFavorites, locate: locate,
                                                                          removeFavorite: reader.removeQuestionFavorite)
            case .practice(let turn): AssistantQuestionPracticeSheet(turn: turn, reader: reader)
            }
        }
    }

    private func sentenceFavoriteButton(_ favorite: AssistantSentenceFavoriteAction) -> some View {
        let noun = favorite.kind.label
        let title = sentenceFavoriteTask != nil ? "正在保存…" : "\(favorite.isSaved ? "已收藏" : "收藏")\(noun)"
        return Button {
            guard sentenceFavoriteTask == nil else { return }
            sentenceFavoriteTask = Task {
                defer { sentenceFavoriteTask = nil }
                do { try await favorite.toggle() }
                catch is CancellationError { return }
                catch { referenceMessage = error.localizedDescription }
            }
        } label: {
            Label(title, systemImage: favorite.isSaved ? "star.fill" : "star")
        }
        .disabled(sentenceFavoriteTask != nil)
        .buttonStyle(ReaderButtonStyle(prominent: favorite.isSaved, compact: true))
        .help(favorite.isSaved ? "取消收藏\(noun)" : favorite.kind == .sentence ? "收藏英文原句和译文" : "收藏原句")
        .accessibilityIdentifier("favorite-\(favorite.kind.rawValue)")
    }

    private func seedReference() {
        guard !suppressesAutomaticReference, chat.reference == nil, chat.turns.isEmpty,
              let suggested = reference(false) else { return }
        chat.replaceReference(with: suggested)
    }

    @ViewBuilder
    private var questionTools: some View {
        @Bindable var chat = chat
        Button("引用当前句") {
            if let current = reference(true) {
                chat.replaceReference(with: current)
                suppressesAutomaticReference = false
                referenceMessage = nil
            } else {
                referenceMessage = "当前没有可引用的英文。"
            }
            focusesDraft = true
        }
        .accessibilityIdentifier("quoteCurrentSentence")
        if let quote = chat.reference {
            Menu("常用追问") {
                ForEach(quote.quickQuestions, id: \.self) { question in
                    Button(question) {
                        chat.insertQuestion(question)
                        focusesDraft = true
                    }
                }
            }
            .accessibilityIdentifier("assistantQuickQuestions")
            if quote.hasSurrounding {
                Toggle("带上前后句", isOn: $chat.includeSurrounding)
                    .accessibilityIdentifier("includeQuestionContext")
            }
            Button("清除引用") {
                suppressesAutomaticReference = true
                chat.replaceReference(with: nil)
                referenceMessage = nil
            }
            .accessibilityIdentifier("clearQuestionReference")
        }
        Button("问答收藏") { sheet = .favorites }
            .accessibilityIdentifier("openAssistantFavorites")
        if !chat.turns.isEmpty {
            Button("开始新问题") {
                chat.startNewConversation()
                referenceMessage = nil
                focusesDraft = true
            }
            .accessibilityIdentifier("newAssistantQuestion")
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if !chat.turns.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9 * scale) {
                        ForEach(chat.turns) { turn in
                            VStack(alignment: .leading, spacing: 5 * scale) {
                                Text(turn.question)
                                    .font(.system(size: 16 * scale, weight: .semibold))
                                    .textSelection(.enabled)
                                if !turn.answer.isEmpty { answer(for: turn) }
                                if turn.isComplete { turnActions(for: turn) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(turn.id)
                        }
                    }
                }
                .frame(maxHeight: 170 * scale)
                .onChange(of: chat.turns.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        if chat.isGenerating {
            Text("本地模型正在回答…")
                .font(.system(size: 14 * scale))
                .foregroundStyle(ReaderPalette.muted)
        }
        if let error = chat.error {
            HStack(alignment: .firstTextBaseline) {
                Text(error).fixedSize(horizontal: false, vertical: true)
                if chat.canRetry {
                    Button("重试") { chat.retry(using: reader.answerQuestion) }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 14 * scale))
            .foregroundStyle(ReaderPalette.muted)
        }
    }

    private func answer(for turn: AssistantQuestionTurn) -> some View {
        let links = AssistantAnswerLinks(answer: turn.answer, reference: turn.isComplete ? turn.reference : nil)
        return AnswerText(answer: links.markdown, fontSize: 16 * scale)
            .environment(\.openURL, OpenURLAction { url in
                guard let reference = turn.reference, let range = links.location(for: url) else { return .discarded }
                openSource(reference, excerpt: range)
                return .handled
            })
            .accessibilityIdentifier("assistantQuestionAnswer")
    }

    private func turnActions(for turn: AssistantQuestionTurn) -> some View {
        let saved = reader.questionFavorites.contains(turn.id)
        let hasOriginal = turn.reference?.hasOriginalPassage == true
        return HStack(spacing: 12 * scale) {
            Button {
                do { try reader.toggleQuestionFavorite(turn, mode: mode) }
                catch { referenceMessage = error.localizedDescription }
            } label: {
                Label(saved ? "已收藏回答" : "收藏回答", systemImage: saved ? "star.fill" : "star")
            }
            .buttonStyle(.link)
            .disabled(!saved && !hasOriginal)
            .help(saved ? "取消收藏回答" : hasOriginal ? "连同原句收藏这条回答" : "引用原句后重新提问即可收藏")
            .accessibilityIdentifier("favoriteAssistantAnswer")
            Menu("回答操作") {
                if let reference = turn.reference, reference.source != nil {
                    Button("回到原文") { openSource(reference, excerpt: nil) }
                        .accessibilityIdentifier("locateAssistantAnswer")
                }
                Button("用一下") { sheet = .practice(turn) }
                    .accessibilityIdentifier("practiceAssistantAnswer")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 14 * scale))
    }

    private func openSource(_ reference: AssistantQuestionReference, excerpt: NSRange?) {
        Task {
            do { try await locate(reference, excerpt) }
            catch is CancellationError { return }
            catch { referenceMessage = error.localizedDescription }
        }
    }

    private var composer: some View {
        @Bindable var chat = chat
        return HStack(spacing: 8 * scale) {
            TextField(chat.reference == nil ? "输入英语问题，或粘贴原句" : "对这句话提问…", text: $chat.draft)
                .font(.system(size: 16 * scale))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10 * scale)
                .frame(height: 40 * scale)
                .background(ReaderPalette.paper, in: RoundedRectangle(cornerRadius: 7 * scale))
                .overlay {
                    RoundedRectangle(cornerRadius: 7 * scale)
                        .strokeBorder(focusesDraft ? ReaderPalette.accent : ReaderPalette.rule)
                        .allowsHitTesting(false)
                }
                .focused($focusesDraft)
                .onSubmit(sendQuestion)
                .accessibilityLabel("英语问题")
                .accessibilityIdentifier("assistantQuestionInput")
            if chat.isGenerating {
                Button(action: chat.stop) {
                    Text("停止").frame(minHeight: 40 * scale)
                }
                .buttonStyle(ReaderButtonStyle(prominent: false, compact: true, scale: 1.2))
                .accessibilityIdentifier("stopAssistantQuestion")
            } else {
                Button(action: sendQuestion) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17 * scale, weight: .semibold))
                        .frame(width: 24 * scale, height: 40 * scale)
                }
                .buttonStyle(ReaderButtonStyle(prominent: true, compact: true, scale: 1.2, primary: true))
                .accessibilityLabel("发送")
                .help("发送（回车）")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!chat.canSend || !isActive)
                .accessibilityIdentifier("sendAssistantQuestion")
            }
        }
    }

    private func sendQuestion() {
        guard isActive, chat.canSend else { return }
        seedReference()
        referenceMessage = nil
        chat.send(using: reader.answerQuestion)
    }
}
