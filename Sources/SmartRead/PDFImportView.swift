import SwiftUI

struct PDFImportView: View {
    let url: URL
    let reader: ReaderModel
    let close: () -> Void
    let back: () -> Void
    let imported: () -> Void
    @State private var document: PDFImportDocument?
    @State private var issue: String?

    var body: some View {
        Group {
            if let document {
                PDFImportEditor(document: document, url: url, reader: reader, close: close, back: back, imported: imported)
            } else {
                VStack(spacing: 16) {
                    if let issue {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(ReaderPalette.warning)
                        Text(issue).multilineTextAlignment(.center)
                        Button("返回", action: back).keyboardShortcut(.cancelAction)
                    } else {
                        ProgressView("正在打开 PDF…")
                        Button("取消", action: close).keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 550, maxHeight: .infinity)
        .background(ReaderPalette.panel)
        .foregroundStyle(ReaderPalette.ink)
        .tint(ReaderPalette.primaryButton)
        .task(id: url) {
            do {
                let opened = try await PDFImportDocument.open(url)
                if !Task.isCancelled { document = opened }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}

private enum PDFPreviewZoom: Int, CaseIterable {
    case fitPage = 0, fitWidth = 100, zoom125 = 125, zoom150 = 150, zoom200 = 200
    case zoom250 = 250, zoom300 = 300, zoom400 = 400

    var title: String {
        switch self {
        case .fitPage: "适合整页"
        case .fitWidth: "适合宽度"
        default: "\(rawValue)%"
        }
    }

    func adjusted(by step: Int) -> Self {
        let modes = Self.allCases
        guard let index = modes.firstIndex(of: self), modes.indices.contains(index + step) else { return self }
        return modes[index + step]
    }

    func width(in viewport: CGSize, aspectRatio: CGFloat) -> CGFloat {
        let width = max(1, viewport.width - 16)
        if self == .fitPage { return min(width, max(1, viewport.height - 16) * aspectRatio) }
        return width * CGFloat(rawValue) / 100
    }
}

private struct PDFImportEditor: View {
    let document: PDFImportDocument
    let url: URL
    let reader: ReaderModel
    let close: () -> Void
    let back: () -> Void
    let imported: () -> Void
    @State private var draft = PDFImportDraft()
    @State private var selectedID: UUID?
    @State private var page = 0
    @State private var pageField = "1"
    @State private var ranges = ""
    @State private var zoom = PDFPreviewZoom.fitWidth
    @State private var preview: (page: Int, image: CGImage)?
    @State private var previewIssue: String?
    @State private var issue: String?
    @State private var title = ""
    @State private var showsCombined = false
    @State private var extraction: Task<Void, Never>?
    @State private var bookImport: Task<Void, Never>?
    @State private var completed = 0
    @State private var total = 0

    private var selectedIndex: Int? { selectedID.flatMap(draft.index(of:)) }
    private var busy: Bool { extraction != nil || bookImport != nil }
    private var suggestedTitle: String {
        draft.pageSummary.isEmpty ? document.name : "\(document.name) · PDF 第 \(draft.pageSummary) 页"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入 PDF").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(document.name).lineLimit(1).foregroundStyle(ReaderPalette.muted)
                }
                Spacer()
                Button("作为电子书打开", action: openAsBook)
                    .accessibilityIdentifier("openPDFAsBook")
                    .disabled(busy || reader.isLoadingPDF)
                Button("返回", action: back).disabled(busy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            HSplitView {
                pagePanel.frame(minWidth: 470, idealWidth: 850, maxWidth: .infinity)
                textPanel.frame(minWidth: 320, idealWidth: 390, maxWidth: 480)
            }
            Divider()
            footer
        }
        .task(id: page) {
            preview = nil
            previewIssue = nil
            let currentPage = page
            do {
                let image = try await document.preview(page: currentPage)
                if !Task.isCancelled, currentPage == page { preview = (currentPage, image) }
            } catch {
                if !Task.isCancelled, currentPage == page { previewIssue = error.localizedDescription }
            }
        }
        .onDisappear {
            extraction?.cancel()
            bookImport?.cancel()
        }
    }

    private func openAsBook() {
        issue = nil
        bookImport = Task {
            defer { bookImport = nil }
            do {
                try await reader.importPDFBook(url)
                if !Task.isCancelled { imported() }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    private var pagePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { showPage(page - 1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上一页").disabled(page == 0)
                TextField("页码", text: $pageField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .accessibilityLabel("PDF 页码")
                    .accessibilityIdentifier("pdfPageNumber")
                    .onSubmit(goToPage)
                Text("/ \(document.pageCount)").monospacedDigit().foregroundStyle(ReaderPalette.muted)
                Button { showPage(page + 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下一页").disabled(page == document.pageCount - 1)
                Spacer()
                Button("加入整页") { addPages([page]) }
                    .accessibilityIdentifier("pdfAddPage")
                    .disabled(busy || draft.parts.contains { $0.page == page })
                zoomControls
            }
            HStack(spacing: 8) {
                TextField("批量页码，例如 2–4, 7", text: $ranges)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pdfPageRanges")
                    .onSubmit(addPageRanges)
                Button("加入这些页", action: addPageRanges)
                    .disabled(busy || ranges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("在预览上拖出矩形，可在同一页连续框选。页码从 PDF 文件第一页算起。")
                .font(.callout).foregroundStyle(ReaderPalette.muted)
            GeometryReader { geometry in
                if let preview, preview.page == page {
                    let aspect = CGFloat(preview.image.width) / CGFloat(preview.image.height)
                    let pageWidth = zoom.width(in: geometry.size, aspectRatio: aspect)
                    ScrollView([.horizontal, .vertical]) {
                        PDFSelectionCanvas(image: preview.image, parts: draft.parts, page: page,
                                           selectedID: selectedID, isEnabled: !busy) { box in
                            selectedID = draft.addBox(box, page: page)
                            showsCombined = false
                            issue = nil
                        }
                        .frame(width: pageWidth, height: pageWidth / aspect)
                        .padding(8)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .id(page)
                } else if let previewIssue {
                    Text(previewIssue).foregroundStyle(ReaderPalette.warning).padding()
                } else {
                    ProgressView("正在显示页面…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(ReaderPalette.chrome, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
    }

    private var zoomControls: some View {
        HStack(spacing: 5) {
            Button { zoom = zoom.adjusted(by: -1) } label: { Image(systemName: "minus") }
                .accessibilityLabel("缩小 PDF 预览")
                .accessibilityIdentifier("pdfZoomOut")
                .disabled(zoom == .fitPage)
            Picker("PDF 预览缩放", selection: $zoom) {
                ForEach(PDFPreviewZoom.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("pdfZoomMode")
            Button { zoom = zoom.adjusted(by: 1) } label: { Image(systemName: "plus") }
                .accessibilityLabel("放大 PDF 预览")
                .accessibilityIdentifier("pdfZoomIn")
                .disabled(zoom == .zoom400)
        }
        .controlSize(.large)
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("文章标题（选填）", text: $title, prompt: Text(suggestedTitle))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("pdfArticleTitle")
            Text("导入顺序").font(.headline)
            if draft.parts.isEmpty {
                Text("框选正文或加入整页后，这里会显示各部分的顺序。")
                    .foregroundStyle(ReaderPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(draft.parts.enumerated()), id: \.element.id) { index, part in
                            partRow(index, part)
                        }
                    }
                }
                .frame(minHeight: 68, idealHeight: 172, maxHeight: 172)
                Picker("预览", selection: $showsCombined) {
                    Text("分段校对").tag(false)
                    Text("合并预览").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if showsCombined {
                    ScrollView {
                        Text(draft.body.isEmpty ? "提取后可查看合并正文。" : draft.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                            .accessibilityIdentifier("pdfCombinedText")
                    }
                    .frame(maxHeight: .infinity)
                    .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 6))
                } else if let index = selectedIndex {
                    partEditor(draft.parts[index], at: index)
                }
            }
        }
        .padding(14)
    }

    private func partRow(_ index: Int, _ part: PDFImportPart) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(ReaderPalette.muted)
                .padding(.leading, 3)
                .draggable(part.id.uuidString)
                .help("拖动调整顺序")
                .allowsHitTesting(!busy)
            Button {
                showPage(part.page)
                selectedID = part.id
                showsCombined = false
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1).  PDF 第 \(part.page + 1) 页 · \(part.box == nil ? "整页" : "框选")")
                        .lineLimit(1)
                    Text(partStatus(part))
                        .font(.caption)
                        .foregroundStyle(part.issue == nil ? ReaderPalette.muted : ReaderPalette.warning)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pdfPart-\(index + 1)")
            .accessibilityAddTraits(selectedID == part.id ? .isSelected : [])

            Button { draft.move(part.id, to: index - 1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("上移第 \(index + 1) 部分").disabled(busy || index == 0)
            Button { draft.move(part.id, to: index + 1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("下移第 \(index + 1) 部分").disabled(busy || index == draft.parts.count - 1)
            Button {
                draft.remove(part.id)
                if selectedID == part.id {
                    selectedID = draft.parts.isEmpty ? nil : draft.parts[min(index, draft.parts.count - 1)].id
                }
            } label: { Image(systemName: "xmark") }
                .accessibilityLabel("删除第 \(index + 1) 部分").disabled(busy)
        }
        .padding(5)
        .background(selectedID == part.id ? ReaderPalette.accentFill : ReaderPalette.card,
                    in: RoundedRectangle(cornerRadius: 6))
        .dropDestination(for: String.self) { items, _ in
            guard !busy, let item = items.first, let id = UUID(uuidString: item), draft.index(of: id) != nil else { return false }
            draft.move(id, to: index)
            return true
        }
    }

    private func partStatus(_ part: PDFImportPart) -> String {
        if let issue = part.issue { return issue }
        guard let text = part.text else { return "待提取" }
        return text.isEmpty ? "未找到文字" : (part.usedOCR ? "本机 OCR" : "PDF 原有文字")
    }

    private func partEditor(_ part: PDFImportPart, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("接到上一段", isOn: Binding(
                get: { draft.parts.first(where: { $0.id == part.id })?.joinsPrevious ?? false },
                set: { value in draft.update(part.id) { $0.joinsPrevious = value } }
            ))
            .accessibilityIdentifier("pdfJoinPrevious")
            .disabled(index == 0 || busy)
            if let issue = part.issue {
                Text(issue).font(.caption).foregroundStyle(ReaderPalette.warning)
            }
            if part.text != nil || part.issue != nil {
                TextEditor(text: Binding(
                    get: { draft.parts.first(where: { $0.id == part.id })?.text ?? "" },
                    set: { value in draft.update(part.id) { $0.text = value; $0.issue = nil } }
                ))
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 80, maxHeight: .infinity)
                .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("第 \(index + 1) 部分文字")
                .accessibilityIdentifier("pdfPartText")
                .disabled(busy)
            } else {
                Text("提取文字后可在这里校对。")
                    .foregroundStyle(ReaderPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Button("用 OCR 识别这一部分") { extract([part], forceOCR: true) }
                .accessibilityIdentifier("pdfRetryOCR")
                .disabled(busy)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue {
                Text(issue).foregroundStyle(ReaderPalette.warning).accessibilityIdentifier("pdfImportIssue")
            }
            HStack {
                if bookImport != nil {
                    ProgressView().controlSize(.small)
                    Text("正在打开电子书…").foregroundStyle(ReaderPalette.muted)
                } else if extraction != nil {
                    ProgressView(value: Double(completed), total: Double(max(1, total))).frame(width: 110)
                    Text("正在提取 \(completed)/\(total)").foregroundStyle(ReaderPalette.muted)
                    Button("停止提取") { extraction?.cancel() }
                } else {
                    Text(draft.parts.isEmpty ? "尚未选择内容" : "已选 \(draft.parts.count) 部分")
                        .foregroundStyle(ReaderPalette.muted)
                }
                Spacer()
                Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("提取文字") { extract(draft.parts.filter { $0.text == nil || $0.issue != nil }) }
                    .accessibilityIdentifier("pdfExtract")
                    .disabled(busy || !draft.parts.contains { $0.text == nil || $0.issue != nil })
                Button("导入文章", action: importArticle)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pdfImportArticle")
                    .disabled(busy || !draft.readyToImport)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func showPage(_ index: Int) {
        guard (0..<document.pageCount).contains(index) else { return }
        page = index
        pageField = String(index + 1)
    }

    private func goToPage() {
        guard let number = Int(pageField.trimmingCharacters(in: .whitespaces)), (1...document.pageCount).contains(number) else {
            issue = "请输入 1–\(document.pageCount) 范围内的 PDF 页码。"
            return
        }
        issue = nil
        showPage(number - 1)
    }

    private func addPageRanges() {
        guard !busy else { return }
        do {
            let pages = try PDFImportDraft.pages(in: ranges, count: document.pageCount)
            addPages(pages)
            ranges = ""
            if let first = pages.first { showPage(first) }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func addPages(_ pages: [Int]) {
        if let first = draft.addPages(pages) {
            selectedID = first
            showsCombined = false
        }
        issue = nil
    }

    private func extract(_ parts: [PDFImportPart], forceOCR: Bool = false) {
        guard !busy, !parts.isEmpty else { return }
        issue = nil
        total = parts.count
        completed = 0
        extraction = Task {
            defer { extraction = nil }
            for part in parts {
                if Task.isCancelled { break }
                do {
                    let result = try await document.extract(part, forceOCR: forceOCR)
                    try Task.checkCancellation()
                    if result.text.isEmpty {
                        reportExtractionIssue("未找到文字。可以重框、手动补入文字或删除这一部分。", part: part)
                    } else {
                        draft.update(part.id) { $0.text = result.text; $0.usedOCR = result.usedOCR; $0.issue = nil }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    reportExtractionIssue(error.localizedDescription, part: part)
                }
                completed += 1
            }
        }
    }

    private func reportExtractionIssue(_ message: String, part: PDFImportPart) {
        if let text = part.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issue = "重识别失败，已保留这部分的原有文字。\n\(message)"
        } else {
            draft.update(part.id) { $0.issue = message }
        }
    }

    private func importArticle() {
        do {
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            try reader.importText(draft.body, title: name.isEmpty ? suggestedTitle : name)
            imported()
        } catch {
            issue = error.localizedDescription
        }
    }
}

struct PDFSelectionCanvas: View {
    let image: CGImage
    let parts: [PDFImportPart]
    let page: Int
    let selectedID: UUID?
    let isEnabled: Bool
    let onBox: (CGRect) -> Void
    @GestureState private var drag: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    if part.page == page {
                        let box = part.box ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                        let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                                          width: box.width * size.width, height: box.height * size.height)
                        mark(rect, number: index + 1, selected: part.id == selectedID)
                    }
                }
                if let drag { mark(drag, number: nil, selected: true) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5)
                .updating($drag) { value, state, _ in
                    if isEnabled { state = rectangle(value, within: size) }
                }
                .onEnded { value in
                    guard isEnabled, size.width > 0, size.height > 0 else { return }
                    let rect = rectangle(value, within: size)
                    guard !rect.isEmpty, rect.width >= 4, rect.height >= 4 else { return }
                    onBox(CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                                 width: rect.width / size.width, height: rect.height / size.height))
                })
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PDF 第 \(page + 1) 页预览，拖动以框选正文")
            .accessibilityIdentifier("pdfPagePreview")
        }
    }

    private func rectangle(_ value: DragGesture.Value, within size: CGSize) -> CGRect {
        CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
               width: abs(value.startLocation.x - value.location.x),
               height: abs(value.startLocation.y - value.location.y))
            .intersection(CGRect(origin: .zero, size: size))
    }

    private func mark(_ rect: CGRect, number: Int?, selected: Bool) -> some View {
        Rectangle()
            .fill(ReaderPalette.primaryButton.opacity(selected ? 0.17 : 0.08))
            .overlay { Rectangle().strokeBorder(ReaderPalette.primaryButton.opacity(selected ? 1 : 0.7), lineWidth: 2) }
            .overlay(alignment: .topLeading) {
                if let number {
                    Text(String(number)).font(.caption.bold().monospacedDigit())
                        .foregroundStyle(ReaderPalette.onAccent)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(ReaderPalette.primaryButton, in: RoundedRectangle(cornerRadius: 4))
                        .padding(2)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}
