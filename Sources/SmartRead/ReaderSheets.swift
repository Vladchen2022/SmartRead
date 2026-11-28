import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case text = "粘贴文本"
        case link = "网页链接"
        case file = "本地文件"
        case book = "PDF 电子书"
        var id: Self { self }
    }

    let reader: ReaderModel
    let openPDF: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.text
    @State private var title = ""
    @State private var text = ""
    @State private var address = ""
    @State private var problem: String?
    @State private var choosingFile = false
    @State private var illustratedBook = false
    @State private var task: Task<Void, Never>?
    @FocusState private var field: Focus?

    private enum Focus { case text, address }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("导入文章").font(.system(size: 25, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Picker("来源", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(reader.isImporting || reader.isLoadingPDF)
            .onChange(of: mode) {
                problem = nil
                focusInput()
            }

            switch mode {
            case .text: textFields
            case .link: linkField
            case .file: fileField
            case .book:
                Label("整本导入，逐页阅读，并在历史记录里继续读。", systemImage: "book.closed")
                    .foregroundStyle(ReaderPalette.muted)
                    .padding(.vertical, 7)
                Toggle("保留插图（图文阅读）", isOn: $illustratedBook)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("importPDFWithFigures")
                    .help("启用阅读同步时，本书的 PDF 原件也会同步")
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(ReaderPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if reader.isImporting || reader.isLoadingPDF {
                    ProgressView().controlSize(.small)
                    Text("正在提取正文…").foregroundStyle(ReaderPalette.muted)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .book ? "选择 PDF…" : mode == .file ? "选取文件…" : "导入") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(mode == .book ? "choosePDFBook" : "submitArticleImport")
                    .disabled(reader.isImporting || reader.isLoadingPDF || inputEmpty)
            }
        }
        .padding(23)
        .frame(width: 520)
        .background(ReaderPalette.panel)
        .foregroundStyle(ReaderPalette.ink)
        .tint(ReaderPalette.primaryButton)
        .task { focusInput() }
        .onDisappear { task?.cancel() }
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: mode == .book ? [.pdf] : [.plainText, UTType(filenameExtension: "md") ?? .plainText, .pdf]
        ) { result in
            do {
                let url = try result.get()
                if mode == .book {
                    task?.cancel()
                    task = Task {
                        do {
                            try await reader.importPDFBook(url, illustrated: illustratedBook)
                            if !Task.isCancelled { dismiss() }
                        } catch {
                            if !Task.isCancelled, !(error is CancellationError) { problem = error.localizedDescription }
                        }
                    }
                } else if url.pathExtension.lowercased() == "pdf" {
                    openPDF(url)
                    dismiss()
                } else {
                    try reader.importFile(url)
                    dismiss()
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private var textFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("标题（选填）", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("英文正文")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReaderPalette.muted)
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: 180)
                .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReaderPalette.rule, lineWidth: 1))
                .focused($field, equals: .text)
                .accessibilityLabel("英文正文")
        }
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("https://", text: $address)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($field, equals: .address)
                .accessibilityLabel("网页地址")
                .onSubmit { submit() }
            Text("支持公开网页和部分 X 帖子。需要登录时，可打开原文并复制正文。")
                .font(.system(size: 12))
                .foregroundStyle(ReaderPalette.muted)
        }
    }

    private var fileField: some View {
        Label("选取 .txt、.md 或 PDF。PDF 可先选页或框选正文。", systemImage: "doc.text")
            .foregroundStyle(ReaderPalette.muted)
            .padding(.vertical, 7)
    }

    private var inputEmpty: Bool {
        switch mode {
        case .text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .link: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file, .book: false
        }
    }

    private func focusInput() {
        switch mode {
        case .text: field = .text
        case .link: field = .address
        case .file, .book: field = nil
        }
    }

    private func submit() {
        guard !reader.isImporting, !reader.isLoadingPDF, !inputEmpty else { return }
        problem = nil
        switch mode {
        case .text:
            do {
                try reader.importText(text, title: title)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        case .link:
            task?.cancel()
            task = Task {
                do {
                    try await reader.importLink(address)
                    dismiss()
                } catch {
                    if !Task.isCancelled { problem = error.localizedDescription }
                }
            }
        case .file, .book:
            choosingFile = true
        }
    }
}
