import SwiftUI

enum AssistantAction: String, CaseIterable {
    case word, phrase, sentence

    var title: String {
        switch self {
        case .word: "查词"
        case .phrase: "搭配"
        case .sentence: "整句解析"
        }
    }
}

struct AssistantActions: View {
    let selected: AssistantAction?
    let available: Set<AssistantAction>
    let perform: (AssistantAction) -> Void
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        HStack(spacing: 6 * scale) {
            ForEach(AssistantAction.allCases, id: \.self) { action in
                Button { perform(action) } label: {
                    Text(action.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ReaderButtonStyle(prominent: selected == action, compact: true))
                .disabled(!available.contains(action))
                .accessibilityAddTraits(selected == action ? .isSelected : [])
                .accessibilityIdentifier("assistantAction-\(action.rawValue)")
            }
        }
    }
}

struct AssistantSourceRow: View {
    let sentence: String
    var timestamp: String? = nil
    let goBack: () -> Void
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * scale) {
            HStack {
                Text(timestamp.map { "原句 · \($0)" } ?? "原句")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(ReaderPalette.muted)
                Spacer()
                Button(action: goBack) {
                    Label("回到原文", systemImage: "location")
                }
                .buttonStyle(.link)
                .font(.system(size: 12 * scale))
                .accessibilityIdentifier("assistantReturnToSource")
            }
            Text(sentence)
                .font(.system(size: 16 * scale, design: .serif))
                .foregroundStyle(ReaderPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("assistantSourceSentence")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AssistantLookupResult {
    case loading(String)
    case answer(String)
    case phrase(StudyResult)
    case failed(String)
}

struct AssistantResult: View {
    let result: AssistantLookupResult
    let fontSize: Double
    let retry: () -> Void

    var body: some View {
        switch result {
        case .loading(let partial):
            if !partial.isEmpty { AnswerText(answer: partial, fontSize: fontSize) }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("等待本地模型…").font(.system(size: 13))
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
