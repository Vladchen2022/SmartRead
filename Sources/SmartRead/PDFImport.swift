import PDFKit
import Vision

struct PDFImportPart: Identifiable, Sendable {
    let id = UUID()
    let page: Int
    // Unit coordinates measured from the top left of the displayed page.
    let box: CGRect?
    var joinsPrevious = false
    var text: String?
    var usedOCR = false
    var issue: String?
}

struct PDFImportDraft {
    private(set) var parts: [PDFImportPart] = []

    mutating func addPages(_ pages: [Int]) -> UUID? {
        var first: UUID?
        var represented = Set(parts.map(\.page))
        for page in pages where represented.insert(page).inserted {
            let part = PDFImportPart(page: page, box: nil)
            parts.append(part)
            if first == nil { first = part.id }
        }
        return first
    }

    mutating func addBox(_ box: CGRect, page: Int) -> UUID {
        var part = PDFImportPart(page: page, box: box)
        if let wholePage = parts.firstIndex(where: { $0.page == page && $0.box == nil }) {
            part.joinsPrevious = parts[wholePage].joinsPrevious
            parts[wholePage] = part
        } else {
            parts.append(part)
        }
        return part.id
    }

    mutating func move(_ id: UUID, to index: Int) {
        guard parts.indices.contains(index), let source = self.index(of: id), source != index else { return }
        let part = parts.remove(at: source)
        parts.insert(part, at: index)
        parts[0].joinsPrevious = false
    }

    mutating func remove(_ id: UUID) {
        parts.removeAll { $0.id == id }
        if !parts.isEmpty { parts[0].joinsPrevious = false }
    }

    func index(of id: UUID) -> Int? { parts.firstIndex { $0.id == id } }

    mutating func update(_ id: UUID, _ change: (inout PDFImportPart) -> Void) {
        if let index = index(of: id) { change(&parts[index]) }
    }

    var readyToImport: Bool {
        !parts.isEmpty && parts.allSatisfy { part in
            part.issue == nil && !(part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    var body: String {
        var result = ""
        for part in parts {
            guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if !result.isEmpty { result += part.joinsPrevious ? " " : "\n\n" }
            result += text
        }
        return result
    }

    var pageSummary: String {
        let numbers = Set(parts.map { $0.page + 1 }).sorted()
        guard let first = numbers.first else { return "" }
        var start = first
        var end = first
        var ranges: [String] = []
        for number in numbers.dropFirst() {
            if number != end + 1 {
                ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
                start = number
            }
            end = number
        }
        ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
        return ranges.joined(separator: ", ")
    }

    static func pages(in input: String, count: Int) throws -> [Int] {
        let normalized = input.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        var result: Set<Int> = []
        let message = "请输入 1–\(count) 范围内的 PDF 页码，例如 2–4, 7。"
        for item in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            let numbers = bounds.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard (1...2).contains(bounds.count), numbers.count == bounds.count,
                  let first = numbers.first, let last = numbers.last, first >= 1, last >= first, last <= count else {
                throw ReaderError.message(message)
            }
            result.formUnion((first - 1)...(last - 1))
        }
        guard !result.isEmpty else { throw ReaderError.message(message) }
        return result.sorted()
    }
}

actor PDFImportDocument {
    nonisolated let pageCount: Int
    nonisolated let name: String
    private let document: PDFDocument
    private let url: URL
    private let accessing: Bool

    init(url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        guard let document = PDFDocument(url: url), document.pageCount > 0, !document.isLocked else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw ReaderError.message("无法打开这个 PDF。若文件有密码，请先用预览解锁并另存后再试。")
        }
        self.url = url
        self.accessing = accessing
        self.document = document
        pageCount = document.pageCount
        name = url.deletingPathExtension().lastPathComponent
    }

    deinit {
        if accessing { url.stopAccessingSecurityScopedResource() }
    }

    nonisolated static func open(_ url: URL) async throws -> PDFImportDocument {
        try await Task.detached(priority: .userInitiated) { try PDFImportDocument(url: url) }.value
    }

    func preview(page index: Int) throws -> CGImage {
        try Task.checkCancellation()
        let page = try page(at: index)
        return try PDFPageRaster(page: page, longEdge: 3800).image()
    }

    func extract(_ part: PDFImportPart, forceOCR: Bool = false) throws -> (text: String, usedOCR: Bool) {
        try Task.checkCancellation()
        let page = try page(at: part.page)
        let raster = try PDFPageRaster(page: page, longEdge: 3400)
        if !forceOCR {
            let embedded: String?
            if let box = part.box {
                let bounds = raster.canvasRect(for: box).applying(raster.transform.inverted())
                embedded = page.selection(for: bounds)?.string
            } else {
                embedded = page.string
            }
            if let embedded, embedded.rangeOfCharacter(from: .alphanumerics) != nil, !embedded.contains("\u{FFFD}") {
                return (Self.reflow(embedded), false)
            }
        }

        let lines = try recognize(raster.image(in: part.box), languages: ["en-US"]).sorted {
            if $0.boundingBox.midY == $1.boundingBox.midY {
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        var result = ""
        var previous: CGRect?
        for line in lines {
            guard let text = line.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let bounds = line.boundingBox
            if let previous {
                let paragraphBreak = previous.minY - bounds.maxY > max(previous.height, bounds.height) * 0.8
                result += paragraphBreak ? "\n\n" : " "
            }
            result += text
            previous = bounds
        }
        return (result, true)
    }

    func embeddedBookText(at index: Int) throws -> String? {
        try Task.checkCancellation()
        let page = try page(at: index)
        guard let raw = page.string, raw.rangeOfCharacter(from: .alphanumerics) != nil,
              !raw.contains("\u{FFFD}") else { return nil }
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return Self.reflow(raw) }
        let lines = selection.selectionsByLine().compactMap { line -> BookLine? in
            guard let text = line.string else { return nil }
            return BookLine(text: text, bounds: line.bounds(for: page))
        }
        // Scans can have a selectable page number or running header over a full-page image.
        let bounds = page.bounds(for: .cropBox)
        let interior = bounds.insetBy(dx: 0, dy: bounds.height * 0.10)
        if !lines.contains(where: { $0.bounds.intersects(interior) && $0.text.contains(where: \.isLetter) }) { return nil }
        let body = Self.bookBody(from: lines)
        return body.isEmpty ? Self.reflow(raw) : body
    }

    func bookChapterHeadings() throws -> [PDFChapterHeading] {
        var headings: [PDFChapterHeading] = []
        for index in 0..<pageCount {
            try Task.checkCancellation()
            let current = try page(at: index)
            guard let raw = current.string,
                  let line = raw.split(whereSeparator: \.isNewline).first(where: {
                      !$0.trimmingCharacters(in: .whitespaces).isEmpty
                  }),
                  let heading = PDFChapterHeading.read(String(line), on: index),
                  heading.number == headings.count + 1 else { continue }
            headings.append(heading)
        }
        return headings
    }

    func bookPage(at index: Int) throws -> PDFBookPage {
        if let text = try embeddedBookText(at: index) { return PDFBookPage(text: text, usedOCR: false) }
        return try recognizeBookPage(at: index, box: nil)
    }

    func recognizeBookPage(at index: Int, box: CGRect?) throws -> PDFBookPage {
        let raster = try PDFPageRaster(page: page(at: index), longEdge: 3400)
        let image = try raster.image(in: box)
        let lines = try recognize(image, languages: ["zh-Hans", "en-US", "zh-Hant"]).compactMap { line -> BookLine? in
            guard let text = line.topCandidates(1).first?.string else { return nil }
            let rect = line.boundingBox
            return BookLine(text: text, bounds: CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                                                        width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)))
        }
        return PDFBookPage(text: Self.bookBody(from: lines), usedOCR: true)
    }

    private func recognize(_ image: CGImage, languages: [String]) throws -> [VNRecognizedTextObservation] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = languages.filter { supported.contains($0) }
        request.automaticallyDetectsLanguage = request.recognitionLanguages.count > 1
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        return request.results ?? []
    }

    private struct BookLine {
        let text: String
        let bounds: CGRect
    }

    private static func bookBody(from fragments: [BookLine]) -> String {
        var groups: [[BookLine]] = []
        for line in fragments.filter({ !$0.bounds.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let first = groups.last?.first, abs(first.bounds.midY - line.bounds.midY) < min(first.bounds.height, line.bounds.height) * 0.45 {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }
        let rows = groups.map { group -> BookLine in
            let pieces = group.sorted { $0.bounds.minX < $1.bounds.minX }
            var text = ""
            for piece in pieces {
                let part = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !PDFBookText.containsChinese(part) { text += " " }
                text += part
            }
            let bounds = pieces.reduce(CGRect.null) { $0.union($1.bounds) }
            return BookLine(text: PDFBookText.normalizeLine(text), bounds: bounds)
        }
        let left = rows.map(\.bounds.minX).min() ?? 0
        var paragraphs: [String] = []
        var previous: BookLine?
        for row in rows where !row.text.isEmpty {
            if let prior = previous, !paragraphs.isEmpty {
                let gap = prior.bounds.midY - row.bounds.midY
                let height = max(prior.bounds.height, row.bounds.height)
                let languageChanged = PDFBookText.containsChinese(prior.text) != PDFBookText.containsChinese(row.text)
                let indented = row.bounds.minX > left + max(10, height * 1.25)
                let followsHeading = paragraphs.count == 1 && paragraphs[0] == prior.text
                    && PDFChapterHeading.read(prior.text, on: 0) != nil
                let startsParagraph = followsHeading || languageChanged || indented || gap > height * 1.75
                if !startsParagraph {
                    paragraphs[paragraphs.count - 1] += (PDFBookText.containsChinese(row.text) ? "" : " ") + row.text
                } else {
                    paragraphs.append(row.text)
                }
            } else {
                paragraphs.append(row.text)
            }
            previous = row
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private func page(at index: Int) throws -> PDFPage {
        guard let page = document.page(at: index) else {
            throw ReaderError.message("找不到 PDF 第 \(index + 1) 页。")
        }
        return page
    }

    private static func reflow(_ text: String) -> String {
        let normalized = Article.normalizedBody(text)
        var result = ""
        var startsParagraph = false
        for line in normalized.components(separatedBy: .newlines) {
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                startsParagraph = true
            } else {
                if !result.isEmpty { result += startsParagraph ? "\n\n" : " " }
                result += content
                startsParagraph = false
            }
        }
        return result
    }
}

private struct PDFPageRaster {
    let page: CGPDFPage
    let canvas: CGRect
    let transform: CGAffineTransform

    init(page: PDFPage, longEdge: CGFloat) throws {
        guard let page = page.pageRef else { throw ReaderError.message("无法读取此页。") }
        let crop = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        guard !crop.isEmpty, crop.width.isFinite, crop.height.isFinite else {
            throw ReaderError.message("此页没有有效的页面尺寸。")
        }
        let rotated = page.rotationAngle % 180 != 0
        let pageSize = CGSize(width: rotated ? crop.height : crop.width, height: rotated ? crop.width : crop.height)
        let scale = longEdge / max(crop.width, crop.height)
        canvas = CGRect(x: 0, y: 0,
                        width: max(1, (scale * pageSize.width).rounded()),
                        height: max(1, (scale * pageSize.height).rounded()))
        self.page = page
        let pageTransform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize),
                                                     rotate: 0, preserveAspectRatio: true)
        transform = pageTransform.concatenating(CGAffineTransform(scaleX: canvas.width / pageSize.width,
                                                                  y: canvas.height / pageSize.height))
    }

    func canvasRect(for box: CGRect) -> CGRect {
        CGRect(x: box.minX * canvas.width, y: (1 - box.maxY) * canvas.height,
               width: box.width * canvas.width, height: box.height * canvas.height)
    }

    func image(in box: CGRect? = nil) throws -> CGImage {
        let slice = box.map { canvasRect(for: $0).integral.intersection(canvas) } ?? canvas
        guard !slice.isEmpty,
              let context = CGContext(data: nil, width: Int(slice.width), height: Int(slice.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ReaderError.message("无法生成所选区域的图像。")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: slice.size))
        context.translateBy(x: -slice.minX, y: -slice.minY)
        context.concatenate(transform)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ReaderError.message("无法生成页面图像。") }
        return image
    }
}
