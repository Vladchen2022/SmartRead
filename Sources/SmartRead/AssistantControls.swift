import SwiftUI

import Observation

struct AssistantSectionTitle: View {
    let title: String
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        Text(title)
            .font(.system(size: max(11, 12 * scale), weight: .medium))
            .foregroundStyle(ReaderPalette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AssistantPassage: View {
    let sentence: String
    var focus: NSRange? = nil
    var timestamp: String? = nil
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                AssistantSectionTitle(title: "整句翻译")
                if let timestamp {
                    Spacer()
                    Text(timestamp).font(.caption.monospacedDigit()).foregroundStyle(ReaderPalette.muted)
                }
            }
            Text(highlightedSentence)
                .font(.system(size: max(14, 17 * scale), design: .serif))
                .textSelection(.enabled)
                .accessibilityIdentifier("assistantSourceSentence")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highlightedSentence: AttributedString {
        var text = AttributedString(sentence)
        if let focus, let range = Range(focus, in: sentence), let selected = Range(range, in: text) {
            text[selected].backgroundColor = Color(nsColor: ReaderPalette.wordHighlightNS)
        }
        return text
    }
}

struct AssistantGrammarRow: View {
    let isExpanded: Bool
    let toggle: () -> Void
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        Button(action: toggle) {
            HStack {
                Text("语法解析")
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(ReaderPalette.muted)
                    .accessibilityHidden(true)
            }
            .font(.system(size: max(12, 14 * scale), weight: .semibold))
            .padding(.vertical, 10 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
        .accessibilityIdentifier("analyzeTranslation")
    }
}

@MainActor
@Observable
final class AssistantLanguageLookup {
    private(set) var result: AssistantLookupResult = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        task = nil
        result = .idle
    }

    func load(_ request: LookupRequest, using reader: ReaderModel) {
        clear()
        result = .loading("")
        task = Task { [weak self] in
            do {
                let answer = try await reader.fetchLanguageAnswer(request) { partial in
                    guard !Task.isCancelled else { return }
                    self?.result = .loading(partial)
                }
                try Task.checkCancellation()
                self?.result = .answer(answer)
            } catch {
                guard !Task.isCancelled else { return }
                self?.result = .failed(ReaderModel.connectionMessage(error))
            }
        }
    }

    func waitForResult() async {
        await task?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .loading = result { result = .failed("已停止，可重试。") }
    }
}

func copyAssistantResult(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

enum AssistantLookupResult {
    case idle
    case loading(String)
    case answer(String)
    case phrase(StudyResult)
    case failed(String)

    var completedText: String? {
        if case .answer(let text) = self, !text.isEmpty { return text }
        return nil
    }
}

struct AssistantResult: View {
    let result: AssistantLookupResult
    let fontSize: Double
    var cancel: (() -> Void)? = nil
    let retry: () -> Void

    var body: some View {
        switch result {
        case .idle: EmptyView()
        case .loading(let partial):
            if !partial.isEmpty { AnswerText(answer: partial, fontSize: fontSize) }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("等待本地模型…").font(.system(size: 13))
                if let cancel { Button("停止", action: cancel).buttonStyle(.link).font(.caption) }
            }
            .foregroundStyle(ReaderPalette.muted)
        case .answer(let answer):
            AnswerText(answer: answer, fontSize: fontSize)
                .accessibilityIdentifier("subtitleLanguageAnswer")
        case .phrase(let phrase):
            if !phrase.overview.isEmpty { AnswerText(answer: phrase.overview, fontSize: fontSize) }
            ForEach(phrase.items) { item in
                let tone = ReaderPalette.highlight(item.style ?? .phrase)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.quote)
                        .font(.system(size: fontSize, design: .serif))
                        .foregroundStyle(Color(nsColor: tone.ink))
                        .padding(5)
                        .background(Color(nsColor: tone.fill), in: RoundedRectangle(cornerRadius: 5))
                        .textSelection(.enabled)
                    if !item.detail.isEmpty { AnswerText(answer: item.detail, fontSize: fontSize) }
                }
            }
            if let note = phrase.note { Text(note).font(.system(size: 13)).foregroundStyle(ReaderPalette.muted) }
            if phrase.overview.isEmpty, phrase.items.isEmpty, phrase.note == nil {
                Text("这句里没有找到明确的搭配。").foregroundStyle(ReaderPalette.muted)
            }
        case .failed(let error):
            Text(error).font(.system(size: 13)).foregroundStyle(ReaderPalette.warning)
            Button("重试", action: retry).buttonStyle(.link)
        }
    }
}
