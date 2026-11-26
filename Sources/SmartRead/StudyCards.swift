import SwiftUI

struct CompactGrammarView: View {
    let result: StudyResult
    let firstSentenceOnly: Bool
    let fontSize: Double
    let locate: (NSRange) -> Void

    private var bodySize: Double { max(15, min(27, fontSize * 0.7)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(firstSentenceOnly ? "首句主干" : "句子主干")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ReaderPalette.accent)
                .accessibilityAddTraits(.isHeader)
            if !result.overview.isEmpty {
                Text(result.overview).font(.system(size: bodySize)).textSelection(.enabled)
            } else if result.items.isEmpty {
                Text("暂未找到可定位的主干。").foregroundStyle(ReaderPalette.muted)
            }
            ForEach(result.items) { item in
                if let style = item.style {
                    let tone = ReaderPalette.highlight(style)
                    Button { locate(item.range) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(style.label).font(.system(size: 12, weight: .medium))
                            Text(item.quote).font(.system(size: bodySize, design: .serif))
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.system(size: max(14, bodySize - 2)))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .foregroundStyle(Color(nsColor: tone.ink))
                        .background(Color(nsColor: tone.fill), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("定位到对应原文")
                }
            }
        }
    }
}

struct StudyCard: View {
    let study: ReaderModel.ActiveStudy
    let reader: ReaderModel
    let fontSize: Double
    let retry: () -> Void
    let dismiss: () -> Void
    let reveal: () -> Void
    let locate: (NSRange) -> Void
    let detailedAnalysis: (TextExcerpt) -> Void

    private var bodySize: Double { max(17, min(28, fontSize * 0.76)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(study.kind.label, systemImage: study.kind.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ReaderPalette.accent)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(study.kind == .check && !study.answerRevealed ? "跳过" : "收起", action: dismiss)
                    .buttonStyle(.link)
            }
            if study.isLoading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在读取原文…")
                }
                .foregroundStyle(ReaderPalette.muted)
            }
            if let problem = study.error {
                Text(problem).foregroundStyle(ReaderPalette.warning)
                if study.request != nil { Button("重试", action: retry) }
            }
            if let result = study.result {
                content(result)
            }
            if let draft = reader.studyFavorite {
                LearningFavoriteButton(reader: reader, draft: draft)
            }
            if study.kind == .structure, let excerpt = study.request?.target {
                Button { detailedAnalysis(excerpt) } label: {
                    Label("完整语法解析", systemImage: "text.magnifyingglass")
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ReaderPalette.rule, lineWidth: 1))
        .padding(16)
    }

    @ViewBuilder
    private func content(_ result: StudyResult) -> some View {
        if study.kind == .check {
            Text(result.question)
                .font(.system(size: bodySize))
                .foregroundStyle(ReaderPalette.ink)
            if study.answerRevealed {
                Text(result.answer)
                    .font(.system(size: bodySize))
                    .foregroundStyle(ReaderPalette.ink)
                    .textSelection(.enabled)
            } else {
                Button("看答案和原文依据", action: reveal)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("revealStudyAnswer")
            }
        } else if !result.overview.isEmpty {
            Text(result.overview)
                .font(.system(size: bodySize))
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        if let note = result.note {
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(ReaderPalette.muted)
        }
        if study.kind != .check || study.answerRevealed {
            ForEach(result.items) { item in
                Button {
                    locate(item.range)
                } label: {
                    sourceRow(item)
                }
                .buttonStyle(.plain)
                .accessibilityHint("在正文定位对应的原文")
                .accessibilityIdentifier("studySource-\(item.id)")
            }
        }
        if result.items.isEmpty, result.overview.isEmpty, result.note == nil {
            Text(study.kind == .hints ? "这段暂无重点提示。" : "这段没有找到明确适用的内容。")
                .foregroundStyle(ReaderPalette.muted)
        }
    }

    private func sourceRow(_ item: StudyResult.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let style = item.style {
                let tone = ReaderPalette.highlight(style)
                HStack {
                    Text(style.label)
                        .font(.system(size: 13))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color(nsColor: tone.ink))
                        .background(Color(nsColor: tone.fill), in: RoundedRectangle(cornerRadius: 5))
                    Spacer(minLength: 0)
                    Image(systemName: "location")
                        .font(.system(size: 13))
                        .foregroundStyle(ReaderPalette.muted)
                        .accessibilityHidden(true)
                }
                Text(item.quote)
                    .font(.system(size: bodySize, design: .serif))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 5)
                    .foregroundStyle(Color(nsColor: tone.ink))
                    .background(Color(nsColor: tone.fill), in: RoundedRectangle(cornerRadius: 4))
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: bodySize - 1))
                        .lineSpacing(4)
                }
            } else {
                HStack {
                    Text("简单英文")
                    Spacer()
                    Label("定位原句", systemImage: "location")
                }
                .font(.system(size: 13))
                .foregroundStyle(ReaderPalette.accent)
                Text(item.detail)
                    .font(.system(size: bodySize, design: .serif))
                    .lineSpacing(4)
                Text(item.quote)
                    .font(.system(size: max(14, bodySize * 0.8), design: .serif))
                    .foregroundStyle(ReaderPalette.muted)
                    .lineSpacing(3)
            }
        }
        .foregroundStyle(ReaderPalette.ink)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderPalette.panel, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
