import SwiftUI

struct AssistantQuestionFavoritesSheet: View {
    let favorites: AssistantQuestionFavorites
    let locate: (AssistantQuestionReference, NSRange?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: AssistantQuestionFavorite.ID?
    @State private var error: String?
    @State private var opening = false
    @State private var task: Task<Void, Never>?

    private var selected: AssistantQuestionFavorite? { favorites.entries.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("问答收藏").font(.title2.bold())
            if let failure = favorites.loadError {
                Text(failure).foregroundStyle(ReaderPalette.warning)
            } else if favorites.entries.isEmpty {
                ContentUnavailableView("暂无问答收藏", systemImage: "bookmark")
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(favorites.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.question).lineLimit(2)
                                Text(sourceLabel(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .tag(entry.id)
                        }
                    }
                    .frame(minWidth: 185, idealWidth: 210)
                    .accessibilityIdentifier("assistantFavoritesList")

                    ScrollView {
                        if let selected {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(sourceLabel(selected)).font(.caption).foregroundStyle(.secondary)
                                if let quote = selected.reference?.passage {
                                    Text(quote).font(.system(size: 16, design: .serif)).textSelection(.enabled)
                                }
                                Text(selected.question).font(.headline).textSelection(.enabled)
                                AnswerText(answer: selected.answer, fontSize: 15)
                                    .environment(\.openURL, OpenURLAction { _ in .discarded })
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        }
                    }
                    .frame(minWidth: 255)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(ReaderPalette.warning) }
            HStack {
                if selected != nil {
                    Button("取消收藏", action: remove)
                        .disabled(opening)
                        .accessibilityIdentifier("removeAssistantFavorite")
                }
                Spacer()
                if opening { ProgressView().controlSize(.small) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                if let reference = selected?.reference, reference.source != nil {
                    Button("回到原文") { open(reference) }
                        .buttonStyle(.borderedProminent)
                        .disabled(opening)
                        .accessibilityIdentifier("locateAssistantFavorite")
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 410)
        .onAppear { selection = favorites.entries.first?.id }
        .onChange(of: selection) { _, _ in error = nil }
        .onDisappear { task?.cancel() }
    }

    private func sourceLabel(_ entry: AssistantQuestionFavorite) -> String {
        [entry.mode.title, entry.reference?.source?.title, entry.reference?.timestamp]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func remove() {
        guard let selected else { return }
        do {
            try favorites.remove(selected.id)
            selection = favorites.entries.first?.id
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ reference: AssistantQuestionReference) {
        opening = true
        error = nil
        task = Task {
            do {
                try await locate(reference, nil)
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                // Closing the sheet cancels any pending navigation.
            } catch { self.error = error.localizedDescription }
            opening = false
        }
    }
}
