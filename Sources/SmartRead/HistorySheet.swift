import SwiftUI

struct HistorySheet: View {
    let reader: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var removal: Removal?
    @State private var problem: String?

    private enum Removal {
        case article(ArticleHistoryEntry)
        case all

        var title: String {
            switch self {
            case .article(let entry): entry.article.pdfPage == nil ? "删除这篇历史文章？" : "移除这本 PDF 的历史记录？"
            case .all: "清空历史记录？"
            }
        }

        var message: String {
            switch self {
            case .article(let entry): "将从历史记录删除《\(entry.article.title)》。"
            case .all: "将删除所有旧文章，保留当前正在阅读的文章。"
            }
        }

        var buttonTitle: String {
            switch self {
            case .article(let entry): entry.article.pdfPage == nil ? "删除文章" : "移除记录"
            case .all: "清空记录"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("历史记录")
                .font(.system(size: 25, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(ArticleStore.RecordFile.allCases.filter { reader.recoveryNeeded.contains($0) }) { kind in
                HStack {
                    Text("\(kind.title)读取失败。恢复会保留原件，优先使用备份。没有可用备份时会建立空记录。")
                    Button("恢复\(kind.title)") {
                        do { try reader.recover(kind); problem = nil }
                        catch { problem = error.localizedDescription }
                    }
                }
            }

            if let progress = reader.pdfProgress(for: reader.article, current: true) {
                Button { dismiss() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(reader.article.title, systemImage: "book.closed").font(.headline)
                        Text("正在阅读 · \(progress)").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("currentPDFBook")
            }

            if let entry = reader.previousReadingEntry {
                Button { open(entry) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(entry.article.pdfPage == nil ? "继续上一篇" : "继续阅读电子书", systemImage: "bookmark")
                            .font(.system(size: 15, weight: .semibold))
                        Text(entry.article.title).lineLimit(1)
                        if let progress = reader.pdfProgress(for: entry.article) { Text(progress).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("resumePreviousArticle")
            }

            if reader.history.isEmpty {
                ContentUnavailableView {
                    Label("暂无历史文章", systemImage: "clock")
                } description: {
                    Text("导入下一篇文章后，当前文章会出现在这里。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(reader.history) { entry in
                            row(entry)
                        }
                    }
                }
                .accessibilityIdentifier("articleHistoryList")
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(ReaderPalette.warning)
            }

            HStack {
                Button("清空历史记录", role: .destructive) { removal = .all }
                    .disabled(reader.history.isEmpty)
                    .accessibilityIdentifier("clearArticleHistory")
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("closeArticleHistory")
            }
            .controlSize(.large)
        }
        .padding(23)
        .frame(width: 620, height: 430)
        .background(ReaderPalette.panel)
        .foregroundStyle(ReaderPalette.ink)
        .tint(ReaderPalette.primaryButton)
        .alert(removal?.title ?? "", isPresented: Binding(
            get: { removal != nil },
            set: { if !$0 { removal = nil } }
        ), presenting: removal) { removal in
            Button("取消", role: .cancel) { }
            Button(removal.buttonTitle, role: .destructive) { remove(removal) }
        } message: { removal in
            Text(removal.message)
        }
    }

    private func row(_ entry: ArticleHistoryEntry) -> some View {
        let article = entry.article
        let title = article.title.isEmpty ? "英文文章" : article.title
        let origin = article.sourceURL?.host ?? "本地文章"
        let date = entry.lastReadAt.formatted(date: .abbreviated, time: .shortened)
        let detail = reader.pdfProgress(for: article).map { "PDF 电子书 · \($0)" } ?? "\(origin) · \(article.wordCount.formatted()) 词"

        return HStack(spacing: 0) {
            Button { open(entry) } label: {
                HStack(spacing: 12) {
                    Image(systemName: article.pdfPage == nil ? "doc.text" : "book.closed").foregroundStyle(ReaderPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 17, weight: .medium)).lineLimit(2)
                        Text("\(detail) · \(date)")
                            .font(.system(size: 12))
                            .foregroundStyle(ReaderPalette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 \(title)")
            .accessibilityIdentifier("openHistoryArticle")

            Button(role: .destructive) { removal = .article(entry) } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ReaderPalette.warning)
            .accessibilityLabel("删除 \(title)")
            .accessibilityIdentifier("deleteHistoryArticle")
            .help("从历史记录删除这篇文章")
        }
        .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(ReaderPalette.rule).allowsHitTesting(false) }
    }

    private func open(_ entry: ArticleHistoryEntry) {
        do {
            try reader.openHistoryArticle(entry.id)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove(_ removal: Removal) {
        do {
            switch removal {
            case .article(let entry): try reader.deleteHistoryArticle(entry.id)
            case .all: try reader.clearHistory()
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
