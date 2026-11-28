import SmartReadSync
import SwiftUI

enum PDFBookPanel: Identifiable {
    case original, chapters, translation, figure(Int)
    var id: String {
        switch self {
        case .original: "original"
        case .chapters: "chapters"
        case .translation: "translation"
        case .figure(let index): "figure-\(index)"
        }
    }
}

struct PDFBookNavigation: View {
    let reader: ReaderModel
    let location: PDFBookLocation
    let present: (PDFBookPanel) -> Void
    @State private var pageNumber = ""
    @State private var task: Task<Void, Never>?
    @State private var chapters: [PDFChapter] = []
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        Group {
            if let reading = location.chapter {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10 * scale) { chapterNavigation(reading); chapterOptions(reading) }
                    VStack(alignment: .leading, spacing: 8 * scale) { chapterNavigation(reading); chapterOptions(reading) }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10 * scale) { navigation; options }
                    VStack(alignment: .leading, spacing: 8 * scale) { navigation; options }
                }
            }
        }
        .disabled(reader.isLoadingPDF)
        .onChange(of: location.index, initial: true) { _, index in pageNumber = String(index + 1) }
        .task(id: location.chapter?.chapter.id) {
            chapters = []
            if location.chapter != nil {
                let available = try? await reader.pdfChapterChoices(for: location.book)
                if !Task.isCancelled { chapters = available ?? [] }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var navigation: some View {
        HStack(spacing: 6 * scale) {
            Button {
                change { await reader.turnPDFPage(-1) }
            } label: {
                Label("上一页", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
            .accessibilityIdentifier("pdfBookPrevious")
            .help("上一页")
            .disabled(location.index == 0)

            TextField("PDF 页码", text: $pageNumber)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13 * scale).monospacedDigit())
                .frame(width: 46 * scale)
                .onSubmit(goToPage)
                .accessibilityIdentifier("pdfBookPageNumber")
                .help("输入 PDF 页码后按回车跳转")
            Text("/ \(location.book.pageCount)")
                .font(.system(size: 13 * scale).monospacedDigit())
                .foregroundStyle(ReaderPalette.muted)
                .fixedSize()
                .accessibilityLabel(location.pageLabel)
                .accessibilityIdentifier("pdfBookProgress")

            Button {
                change { await reader.turnPDFPage(1) }
            } label: {
                Label("下一页", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
            .accessibilityIdentifier("pdfBookNext")
            .help("下一页")
            .disabled(location.index == location.book.pageCount - 1)

            if reader.isLoadingPDF { ProgressView().controlSize(.small).accessibilityLabel("正在载入 PDF 页") }
        }
        .fixedSize()
    }

    private var illustratedModeButton: some View {
        Button {
            change { await reader.setPDFIllustrated(location.illustrated == nil) }
        } label: {
            Label(location.illustrated == nil ? "图文阅读" : "纯文字", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
        .accessibilityIdentifier("togglePDFIllustrated")
        .help("图文阅读保留原页插图，已连接 iCloud 时同步 PDF 原件")
    }

    private var options: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6 * scale) { pageOptionButtons }
                .fixedSize()
            Menu { pageOptionButtons } label: {
                Label("PDF 选项", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("pdfReadingOptions")
        }
    }

    @ViewBuilder private var pageOptionButtons: some View {
        Button {
            change {
                if !(await reader.startPDFChapterReading()) { present(.chapters) }
            }
        } label: {
            Label("按章阅读", systemImage: "book")
        }
        .buttonStyle(ReaderButtonStyle(prominent: true, compact: true))
        .accessibilityIdentifier("pdfReadByChapter")

        Button {
            change { await reader.setPDFEnglishOnly(!location.englishOnly) }
        } label: {
            Label("只读英文", systemImage: location.englishOnly ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(ReaderButtonStyle(prominent: location.englishOnly, compact: true))
        .accessibilityIdentifier("pdfBookEnglishOnly")
        .accessibilityValue(location.englishOnly ? "开启" : "关闭")
        .help(location.englishOnly ? "点击显示所有页面和中文" : location.illustrated == nil
              ? "点击只显示英文，翻页时跳过纯中文页" : "点击只显示英文，翻页时保留含插图的页面")

        Button { present(.original) } label: { Label("查看原页", systemImage: "doc.richtext") }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
            .accessibilityIdentifier("pdfBookOriginal")
        illustratedModeButton
    }

    private func chapterNavigation(_ reading: PDFChapterReading) -> some View {
        HStack(spacing: 6 * scale) {
            let first = reading.chapter.firstPage
            let last = reading.chapter.lastPage
            chapterStep("上一章", symbol: "chevron.left", id: "pdfPreviousChapter",
                        chapter: chapters.last { $0.lastPage < first })
            Button {
                present(.chapters)
            } label: {
                Label(reading.chapter.label, systemImage: "list.bullet")
            }
            .buttonStyle(ReaderButtonStyle(prominent: true, compact: true))
            .help("打开章节目录或手动选页")
            .accessibilityIdentifier("pdfChapterDirectory")
            chapterStep("下一章", symbol: "chevron.right", id: "pdfNextChapter",
                        chapter: chapters.first { $0.firstPage > last })
            if reader.isLoadingPDF { ProgressView().controlSize(.small).accessibilityLabel("正在载入章节") }
        }
        .fixedSize()
    }

    private func chapterStep(_ label: String, symbol: String, id: String, chapter: PDFChapter?) -> some View {
        Button {
            guard let chapter else { return }
            change {
                do { try await reader.loadPDFChapter(chapter) }
                catch { if !(error is CancellationError) { reader.notice = error.localizedDescription } }
            }
        } label: {
            Label(label, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
        .accessibilityIdentifier(id)
        .help(label)
        .disabled(chapter == nil)
    }

    private func chapterOptions(_ reading: PDFChapterReading) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6 * scale) { chapterOptionButtons(reading) }
            VStack(alignment: .leading, spacing: 6 * scale) { chapterOptionButtons(reading) }
        }
    }

    @ViewBuilder
    private func chapterOptionButtons(_ reading: PDFChapterReading) -> some View {
        Button { present(.translation) } label: { Label("本章译文", systemImage: "text.quote") }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
            .accessibilityIdentifier("pdfChapterTranslation")
            .disabled(reading.translation.isEmpty)

        Button { present(.original) } label: { Label("查看原页", systemImage: "doc.richtext") }
            .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
            .accessibilityIdentifier("pdfBookOriginal")

        Button {
            change { await reader.openPDFPageView() }
        } label: {
            Label("按页阅读", systemImage: "doc")
        }
        .buttonStyle(ReaderButtonStyle(prominent: false, compact: true))
        .accessibilityIdentifier("pdfReadByPage")

        illustratedModeButton
    }

    private func goToPage() {
        guard let requested = Int(pageNumber.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...location.book.pageCount).contains(requested) else {
            pageNumber = String(location.index + 1)
            reader.notice = "请输入 1–\(location.book.pageCount) 范围内的 PDF 页码。"
            return
        }
        change { await reader.jumpToPDFPage(requested) }
    }

    private func change(_ operation: @escaping @MainActor () async -> Void) {
        guard !reader.isLoadingPDF else { return }
        task = Task { await operation() }
    }
}

struct PDFBookFigurePreview: View {
    let reader: ReaderModel
    let location: PDFBookLocation
    let index: Int
    let figure: ReadingPDFFigure
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var issue: String?
    @State private var zoom: CGFloat = 1
    @State private var request = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("PDF 第 \(location.index + 1) 页 · 插图 \(index + 1)").font(.headline)
                Spacer()
                Button("缩小", systemImage: "minus.magnifyingglass") { zoom = max(1, zoom / 1.4) }
                    .labelStyle(.iconOnly).disabled(image == nil || zoom == 1)
                Button("放大", systemImage: "plus.magnifyingglass") { zoom = min(5, zoom * 1.4) }
                    .labelStyle(.iconOnly).disabled(image == nil || zoom == 5)
                Button("适合窗口") { zoom = 1 }.disabled(zoom == 1)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let image {
                GeometryReader { geometry in
                    let fit = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: CGFloat(image.width) * fit * zoom, height: CGFloat(image.height) * fit * zoom)
                            .accessibilityLabel("PDF 插图")
                            .accessibilityIdentifier("pdfEnlargedFigure")
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                }
            } else if let issue {
                Text(issue).foregroundStyle(ReaderPalette.warning)
                Button("重试") { request += 1 }
                Spacer()
            } else {
                ProgressView("正在加载插图…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(15)
        .frame(minWidth: 530, idealWidth: 850, minHeight: 400, idealHeight: 650)
        .background(ReaderPalette.panel)
        .task(id: request) {
            issue = nil
            do {
                let loaded = try await reader.pdfFigurePreview(location, figure: figure, longEdge: 3800)
                if !Task.isCancelled { image = loaded }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}

struct PDFBookOriginalPage: View {
    let reader: ReaderModel
    let location: PDFBookLocation
    let pageIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var error: String?
    @State private var draft = PDFImportDraft()
    @State private var selecting = false
    @State private var correction: Task<Void, Never>?
    private var pageLabel: String { "第 \(pageIndex + 1)/\(location.book.pageCount) 页" }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(pageLabel).font(.headline)
                Spacer()
                Group {
                    if selecting {
                        Button("撤销上一个框") { if let last = draft.parts.last { draft.remove(last.id) } }
                            .disabled(draft.parts.isEmpty)
                        Button("按选框顺序识别") { correct(boxes: draft.parts.compactMap(\.box)) }
                            .disabled(draft.parts.isEmpty)
                        Button("取消框选") { selecting = false }
                    } else {
                        Button("按顺序框选") { selecting = true }
                        Button("重新 OCR 整页") { correct(boxes: []) }
                    }
                }
                .disabled(correction != nil || image == nil)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if correction != nil { ProgressView("正在识别本页…") }
            if let error { Text(error).foregroundStyle(ReaderPalette.warning) }
            GeometryReader { geometry in
                if let image {
                    ScrollView {
                        Group {
                            if selecting {
                                PDFSelectionCanvas(image: image, parts: draft.parts, page: pageIndex,
                                                   selectedID: draft.parts.last?.id, isEnabled: correction == nil) { box in
                                    _ = draft.addBox(box, page: pageIndex)
                                }
                                .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                            } else {
                                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            }
                        }
                        .frame(width: max(1, geometry.size.width - 16))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("PDF 原页，\(pageLabel)")
                    }
                } else if error == nil {
                    ProgressView("正在加载原页…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(15)
        .frame(minWidth: 530, minHeight: 430, idealHeight: 650)
        .background(ReaderPalette.panel)
        .task {
            do {
                image = try await reader.pdfPagePreview(location, at: pageIndex)
                for box in try await reader.pdfBoxes(location.book, at: pageIndex) { _ = draft.addBox(box, page: pageIndex) }
            }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { correction?.cancel() }
    }

    private func correct(boxes: [CGRect]) {
        error = nil
        correction = Task {
            defer { correction = nil }
            do {
                try await reader.correctPDF(location, at: pageIndex, boxes: boxes)
                dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct PDFChapterBrowser: View {
    let reader: ReaderModel
    let location: PDFBookLocation
    @Environment(\.dismiss) private var dismiss
    @State private var chapters: [PDFChapter]?
    @State private var showsManual = false
    @State private var first = ""
    @State private var last = ""
    @State private var join: PDFChapterJoin = .automatic
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("章节目录").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let chapters {
                if chapters.isEmpty {
                    Text("请输入本章的起止页。SmartRead 会从所选页提取英文。")
                        .foregroundStyle(ReaderPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(chapters) { chapter in
                                Button { open(chapter) } label: {
                                    HStack {
                                        Text(chapter.menuLabel).lineLimit(2)
                                        Spacer()
                                        Text(chapter.sourceLabel).foregroundStyle(ReaderPalette.muted)
                                        if location.chapter?.chapter == chapter {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(ReaderButtonStyle(prominent: location.chapter?.chapter == chapter, compact: true))
                                .accessibilityIdentifier("pdfChapter-\(chapter.heading?.number ?? 0)")
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                    .disabled(reader.isLoadingPDF)
                }
            } else {
                ProgressView("正在查找章标题…")
            }

            DisclosureGroup("手动选页", isExpanded: $showsManual) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        TextField("起始页", text: $first).frame(width: 64)
                            .accessibilityIdentifier("pdfChapterFirstPage")
                        Text("至")
                        TextField("结束页", text: $last).frame(width: 64)
                            .accessibilityIdentifier("pdfChapterLastPage")
                        Text("/ \(location.book.pageCount)").foregroundStyle(ReaderPalette.muted)
                        Spacer()
                        Picker("跨页", selection: $join) {
                            ForEach(PDFChapterJoin.allCases) { Text($0.label).tag($0) }
                        }
                        .fixedSize()
                    }
                    Text("英文会连续显示，选中页内的中文可在「本章译文」查看。")
                        .font(.callout)
                        .foregroundStyle(ReaderPalette.muted)
                    Button("打开所选页", action: openRange)
                        .buttonStyle(ReaderButtonStyle(prominent: true, compact: true))
                        .accessibilityIdentifier("pdfChapterOpenRange")
                }
                .padding(.top, 9)
                .textFieldStyle(.roundedBorder)
            }
            .disabled(reader.isLoadingPDF)

            if reader.isLoadingPDF {
                ProgressView("正在载入章节…")
            }
            if let error {
                Text(error).foregroundStyle(ReaderPalette.warning)
            }
        }
        .padding(18)
        .frame(width: 500)
        .background(ReaderPalette.panel)
        .task(id: location.book.id) {
            let range = location.chapter?.chapter
            first = String((range?.firstPage ?? location.index) + 1)
            last = String((range?.lastPage ?? location.index) + 1)
            join = location.chapter?.join ?? .automatic
            do {
                chapters = try await reader.pdfChapterChoices(for: location.book)
                if chapters?.isEmpty == true { showsManual = true }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    chapters = []
                    showsManual = true
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func openRange() {
        guard let start = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int(last.trimmingCharacters(in: .whitespacesAndNewlines)),
              start >= 1, end >= start, end <= location.book.pageCount else {
            error = "请输入 1–\(location.book.pageCount) 范围内的起止页。"
            return
        }
        let chapter = PDFChapter(firstPage: start - 1, lastPage: end - 1, heading: nil)
        open(chapter, join: join)
    }

    private func open(_ chapter: PDFChapter, join: PDFChapterJoin = .automatic) {
        guard !reader.isLoadingPDF, task == nil else { return }
        error = nil
        task = Task {
            defer { task = nil }
            do {
                try await reader.loadPDFChapter(chapter, join: join)
                if !Task.isCancelled { dismiss() }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
}

struct PDFChapterTranslation: View {
    let reading: PDFChapterReading
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(reading.chapter.label) · 中文译文").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(reading.translation)
                    .font(.system(size: 17 * scale))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("pdfChapterTranslationText")
            }
        }
        .padding(18)
        .frame(minWidth: 500, minHeight: 400, idealHeight: 620)
        .background(ReaderPalette.paper)
    }
}
