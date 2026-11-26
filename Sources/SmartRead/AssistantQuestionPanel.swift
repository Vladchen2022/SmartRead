import SwiftUI

struct AssistantQuestionPanel: View {
    let reader: ReaderModel
    let mode: ReaderMode
    let materialID: String?
    let locate: (AssistantQuestionReference, NSRange?) async throws -> Void
    var isActive = true
    let manualSelection: AssistantQuestionSelection?
    let reference: (_ currentOnly: Bool) -> AssistantQuestionReference?

    @State private var isExpanded = false
    @State private var referenceMessage: String?
    @State private var sheet: PanelSheet?
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
        Divider()
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(spacing: 8 * scale) {
                Button {
                    if !isExpanded, chat.reference == nil, chat.turns.isEmpty, chat.draft.isEmpty {
                        chat.replaceReference(with: reference(false))
                    }
                    isExpanded.toggle()
                    focusesDraft = isExpanded
                } label: {
                    Label("问 AI", systemImage: isExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14 * scale, weight: .semibold))
                .accessibilityLabel(isExpanded ? "收起问 AI" : "展开问 AI")
                .accessibilityIdentifier("toggleAssistantQuestion")
                Spacer(minLength: 0)
                if isExpanded {
                    Button("引用当前句") {
                        if let current = reference(true) {
                            chat.replaceReference(with: current)
                            referenceMessage = nil
                        } else {
                            referenceMessage = "当前没有可引用的英文。"
                        }
                        focusesDraft = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12 * scale))
                    .accessibilityIdentifier("quoteCurrentSentence")
                    Button {
                        sheet = .favorites
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .buttonStyle(.plain)
                    .help("问答收藏")
                    .accessibilityLabel("问答收藏")
                    .accessibilityIdentifier("openAssistantFavorites")
                    if !chat.turns.isEmpty {
                        Button {
                            chat.startNewConversation()
                            referenceMessage = nil
                            focusesDraft = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .buttonStyle(.plain)
                        .help("开始新问题")
                        .accessibilityLabel("开始新问题")
                        .accessibilityIdentifier("newAssistantQuestion")
                    }
                }
            }
            if isExpanded {
                referencePreview
                quickQuestions
                transcript
                composer
            }
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isActive) { _, active in
            if !active { chat.stop(); focusesDraft = false }
        }
        .onChange(of: materialID, initial: true) { _, material in
            chat.activate(material: material)
            referenceMessage = nil
        }
        .onChange(of: manualSelection, initial: true) { _, selection in
            guard let selection else { return }
            chat.selectReference(selection)
            referenceMessage = nil
        }
        .onDisappear { chat.stop() }
        .sheet(item: $sheet) { selection in
            switch selection {
            case .favorites: AssistantQuestionFavoritesSheet(favorites: reader.questionFavorites, locate: locate)
            case .practice(let turn): AssistantQuestionPracticeSheet(turn: turn, reader: reader)
            }
        }
    }

    @ViewBuilder
    private var quickQuestions: some View {
        if let reference = chat.reference {
            Menu("常用追问") {
                ForEach(reference.quickQuestions, id: \.self) { question in
                    Button(question) {
                        chat.insertQuestion(question)
                        focusesDraft = true
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12 * scale))
            .accessibilityIdentifier("assistantQuickQuestions")
        }
    }

    @ViewBuilder
    private var referencePreview: some View {
        @Bindable var chat = chat
        if let quote = chat.reference {
            VStack(alignment: .leading, spacing: 4 * scale) {
                HStack {
                    Text(quote.timestamp.map { "引用 · \($0)" } ?? "引用原文")
                        .foregroundStyle(ReaderPalette.muted)
                    Spacer(minLength: 0)
                    Button {
                        chat.replaceReference(with: nil)
                        referenceMessage = nil
                        focusesDraft = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除引用")
                    .accessibilityIdentifier("clearQuestionReference")
                }
                Text(quote.passage)
                    .font(.system(size: 14 * scale, design: .serif))
                    .lineLimit(3)
                    .help(quote.passage)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistantQuestionPassage")
                if let focus = quote.focus {
                    Text("选中 · \(focus)")
                        .lineLimit(1)
                        .foregroundStyle(ReaderPalette.muted)
                }
                if quote.hasSurrounding {
                    Toggle("带上前后句", isOn: $chat.includeSurrounding)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("includeQuestionContext")
                }
            }
            .font(.system(size: 12 * scale))
            .padding(8 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 8 * scale))
        }
        if let referenceMessage {
            Text(referenceMessage).font(.system(size: 12 * scale)).foregroundStyle(ReaderPalette.muted)
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
                                    .font(.system(size: 13 * scale, weight: .semibold))
                                    .textSelection(.enabled)
                                if !turn.answer.isEmpty { answer(for: turn) }
                                if turn.isComplete { turnActions(for: turn) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(turn.id)
                        }
                    }
                }
                .frame(maxHeight: 150 * scale)
                .onChange(of: chat.turns.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        if chat.isGenerating {
            Text("本地模型正在回答…")
                .font(.system(size: 12 * scale))
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
            .font(.system(size: 12 * scale))
            .foregroundStyle(ReaderPalette.muted)
        }
    }

    private func answer(for turn: AssistantQuestionTurn) -> some View {
        let links = AssistantAnswerLinks(answer: turn.answer, reference: turn.isComplete ? turn.reference : nil)
        return AnswerText(answer: links.markdown, fontSize: 14 * scale)
            .environment(\.openURL, OpenURLAction { url in
                guard let reference = turn.reference, let range = links.location(for: url) else { return .discarded }
                openSource(reference, excerpt: range)
                return .handled
            })
            .accessibilityIdentifier("assistantQuestionAnswer")
    }

    private func turnActions(for turn: AssistantQuestionTurn) -> some View {
        HStack(spacing: 10 * scale) {
            if let reference = turn.reference, reference.source != nil {
                Button("回到原文") { openSource(reference, excerpt: nil) }
                    .accessibilityIdentifier("locateAssistantAnswer")
            }
            Button(reader.questionFavorites.contains(turn.id) ? "已收藏" : "收藏") {
                do { try reader.questionFavorites.toggle(turn, mode: mode) }
                catch { referenceMessage = error.localizedDescription }
            }
            .accessibilityIdentifier("favoriteAssistantAnswer")
            Button("用一下") { sheet = .practice(turn) }
                .accessibilityIdentifier("practiceAssistantAnswer")
        }
        .buttonStyle(.link)
        .font(.system(size: 12 * scale))
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
        return HStack(alignment: .bottom, spacing: 6 * scale) {
            TextField(chat.reference == nil ? "输入英语问题，或粘贴原句" : "想问这句的什么？",
                      text: $chat.draft, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 13 * scale))
                .textFieldStyle(.roundedBorder)
                .focused($focusesDraft)
                .accessibilityLabel("英语问题")
                .accessibilityIdentifier("assistantQuestionInput")
            if chat.isGenerating {
                Button("停止", action: chat.stop)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("stopAssistantQuestion")
            } else {
                Button("发送") {
                    referenceMessage = nil
                    chat.send(using: reader.answerQuestion)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!chat.canSend || !isActive)
                .accessibilityIdentifier("sendAssistantQuestion")
            }
        }
        .controlSize(scale < 0.8 ? .small : .regular)
    }
}
