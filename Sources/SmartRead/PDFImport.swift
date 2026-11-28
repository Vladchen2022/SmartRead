import PDFKit
import SmartReadSync
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
                return (ReadingPDFLayout.reflow(embedded), false)
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
        return ReadingPDFLayout.embeddedText(page)
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
        let text = try ReadingPDFLayout.recognizedText(page(at: index), box: box)
        return PDFBookPage(text: text, usedOCR: true)
    }

    func illustratedBookPage(at index: Int, englishOnly: Bool, correction: PDFBookPage? = nil) throws -> PDFBookPage {
        let result = try ReadingPDFLayout.illustratedPage(page(at: index), englishOnly: englishOnly, correction: correction?.text)
        return PDFBookPage(text: result.text, usedOCR: result.usedOCR, figures: result.figures, normalizedText: result.normalizedText)
    }

    func renderedFigure(at index: Int, figure: ReadingPDFFigure, longEdge: CGFloat) throws -> CGImage {
        try Task.checkCancellation()
        let raster = try PDFPageRaster(page: page(at: index), longEdge: longEdge)
        return try raster.image(in: figure.rect)
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

    private func page(at index: Int) throws -> PDFPage {
        guard let page = document.page(at: index) else {
            throw ReaderError.message("找不到 PDF 第 \(index + 1) 页。")
        }
        return page
    }
}

private typealias PDFPageRaster = ReadingPDFPageRaster

private extension ReadingPDFPageRaster {
    init(page: PDFPage, longEdge: CGFloat) throws {
        guard let source = page.pageRef else { throw ReadingSyncError.invalidPDF }
        try self.init(page: source, longEdge: longEdge)
    }
}
