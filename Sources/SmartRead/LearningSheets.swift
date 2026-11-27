import SwiftUI

struct LearningFavoriteButton: View {
    let reader: ReaderModel
    let draft: LearningFavorite.Draft
    var controlScale: CGFloat = 2

    var body: some View {
        let saved = reader.isFavorite(draft)
        Button {
            do {
                try reader.toggleFavorite(draft)
            } catch {
                reader.notice = "无法更新收藏。\n\(error.localizedDescription)"
            }
        } label: {
            Label("\(saved ? "已收藏" : "收藏")\(draft.kind.label)", systemImage: saved ? "star.fill" : "star")
        }
        .buttonStyle(ReaderButtonStyle(prominent: saved, compact: true, scale: controlScale))
        .help(saved ? "取消收藏\(draft.kind.label)" : "保存到\(reader.favoritesTitle)")
        .accessibilityIdentifier("favorite-\(draft.kind.rawValue)")
    }
}

struct ReadingFeedbackSheet: View {
    let reader: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var difficulty: ReadingDifficulty?
    @State private var reason: ReadingDifficultyReason?
    @State private var feedback: String
    @State private var problem: String?

    init(reader: ReaderModel) {
        self.reader = reader
        _difficulty = State(initialValue: reader.learningRecord?.reading.difficulty)
        _reason = State(initialValue: reader.learningRecord?.reading.difficultyReason)
        _feedback = State(initialValue: reader.learningRecord?.reading.feedback ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("完成阅读").font(.title2)
            Text(reader.article.title).font(.headline)
            Picker("文章难度", selection: $difficulty) {
                ForEach(ReadingDifficulty.allCases) { difficulty in
                    Text(difficulty.label).tag(Optional(difficulty))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("readingDifficulty")
            VStack(alignment: .leading, spacing: 7) {
                Text("阅读卡点（可选）").foregroundStyle(ReaderPalette.muted)
                HStack(spacing: 6) {
                    ForEach(ReadingDifficultyReason.allCases) { choice in
                        Button { reason = reason == choice ? nil : choice } label: {
                            Text(choice.label)
                        }
                        .buttonStyle(ReaderButtonStyle(prominent: reason == choice))
                        .accessibilityValue(reason == choice ? "已选择" : "未选择")
                        .accessibilityIdentifier("difficultyReason-\(choice.rawValue)")
                    }
                }
            }
            TextField("阅读感受（可选）", text: $feedback, axis: .vertical)
                .lineLimit(3...5)
                .accessibilityIdentifier("readingFeedback")
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(ReaderPalette.warning)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认完成", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(difficulty == nil)
                    .accessibilityIdentifier("confirmReadingCompleted")
            }
        }
        .padding(24)
        .frame(width: 470)
        .controlSize(.large)
        .background(ReaderPalette.panel)
        .onChange(of: reader.articleVersion) { dismiss() }
    }

    private func save() {
        guard let difficulty else { return }
        do {
            try reader.completeReading(difficulty: difficulty, feedback: feedback, reason: reason)
            dismiss()
        } catch {
            problem = "无法保存阅读反馈。\(error.localizedDescription)"
        }
    }
}

struct ArticleFavoritesSheet: View {
    let reader: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reader.favoritesTitle).font(.title2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(reader.favorites) { entry in
                        let favorite = entry.favorite
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(favorite.kind.label).foregroundStyle(ReaderPalette.accent)
                                if let source = entry.pdfSource {
                                    Text(source).font(.caption).foregroundStyle(ReaderPalette.muted)
                                }
                                Spacer()
                                Button("回到原句") { show(favorite) }
                                    .buttonStyle(ReaderButtonStyle(prominent: false))
                                    .accessibilityIdentifier("showSavedFavorite")
                                Button("取消收藏") { remove(favorite) }.buttonStyle(.link)
                            }
                            Text(favorite.displayQuote).font(.headline).textSelection(.enabled)
                            if favorite.sentence != favorite.displayQuote {
                                Text(favorite.sentence).foregroundStyle(ReaderPalette.muted).textSelection(.enabled)
                            }
                            let result = [favorite.result.definition, favorite.result.translation, favorite.result.analysis]
                                .compactMap { $0 }.joined(separator: "\n\n")
                            AnswerText(answer: result, fontSize: 17)
                        }
                        .padding(14)
                        .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if reader.favoriteCount == 0 {
                        Text(reader.article.pdfPage == nil ? "本篇暂无收藏" : "本书暂无收藏")
                            .foregroundStyle(ReaderPalette.muted)
                    }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(ReaderPalette.warning)
            }
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 520, height: 455)
        .controlSize(.large)
        .background(ReaderPalette.panel)
        .onChange(of: reader.articleVersion) { dismiss() }
    }

    private func remove(_ favorite: LearningFavorite) {
        do {
            try reader.removeFavorite(favorite.id)
            problem = nil
        } catch {
            problem = "无法取消收藏。\(error.localizedDescription)"
        }
    }

    private func show(_ favorite: LearningFavorite) {
        do {
            try reader.showFavorite(favorite.id)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
