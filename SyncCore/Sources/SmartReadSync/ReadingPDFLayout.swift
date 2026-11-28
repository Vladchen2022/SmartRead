import PDFKit
import Vision

public enum ReadingPDFText {
    private static let latin = try! NSRegularExpression(pattern: #"\p{Script=Latin}"#)
    private static let chapterHeading = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:chapter\s+([1-9][0-9]?)\b|([1-9][0-9]?)\s*[.．]?\s+\p{Script=Latin})"#
    )
    private static let han = try! NSRegularExpression(pattern: #"\p{Script=Han}"#)

    public static func chapterNumber(in text: String) -> Int? {
        guard text.count <= 110, isEnglish(text),
              let match = chapterHeading.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let numberRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        return Range(numberRange, in: text).flatMap { Int(text[$0]) }
    }

    public static func containsChinese(_ text: String) -> Bool {
        han.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func isEnglish(_ text: String) -> Bool {
        !containsChinese(text) && latin.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func englishOnly(_ text: String) -> String {
        text.components(separatedBy: "\n\n").filter(isEnglish).joined(separator: "\n\n")
    }

    public static func normalizeLine(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnglish(line) else { return line }
        let spaced = line.replacingOccurrences(of: #"([．！？；：，])(?=[A-Za-z])"#, with: "$1 ", options: .regularExpression)
        return (spaced.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? spaced)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
    }

    public static func hasSentenceEnding(_ text: String) -> Bool {
        let sentence = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: #""'’”)]」"#)))
        return sentence.last.map { ".!?…。！？".contains($0) } ?? false
    }
}

public enum ReadingPDFLayout {
    public struct IllustratedPage: Sendable {
        public let text: String
        public let usedOCR: Bool
        public let normalizedText: Bool
        public let figures: [ReadingPDFFigure]

        public func presentation(pageCount: Int) -> ReadingPDFPage {
            ReadingPDFPage(pageCount: pageCount, figures: figures, normalizedText: normalizedText ? true : nil)
        }

        /// Build the same material ID and UTF-16 anchors on Mac, iPhone and iPad.
        public func material(title: String, bookID: String, pageIndex: Int, pageCount: Int,
                             englishOnly: Bool) throws -> ReadingMaterial {
            guard (0..<max(0, pageCount)).contains(pageIndex), ReadingPDFPage.isValidBookID(bookID) else {
                throw ReadingSyncError.invalidPDF
            }
            let key = ReadingPDFPage.legacyKey(bookID: bookID, index: pageIndex, englishOnly: englishOnly, normalized: normalizedText)
            var item = try ReadingMaterial(title: title, body: text, legacyKey: key,
                                           illustratedPDF: presentation(pageCount: pageCount))
            item.bookID = bookID
            item.page = pageIndex + 1
            return item
        }
    }

    public static func embeddedText(_ page: PDFPage) -> String? { embeddedBookPage(page)?.text }

    public static func recognizedText(_ page: PDFPage, box: CGRect?) throws -> String {
        try Task.checkCancellation()
        guard let source = page.pageRef else { throw ReadingSyncError.invalidPDF }
        let raster = try ReadingPDFPageRaster(page: source, longEdge: 3400)
        let image = try raster.image(in: box)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "en-US", "zh-Hant"].filter(supported.contains)
        request.automaticallyDetectsLanguage = request.recognitionLanguages.count > 1
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        let lines = (request.results ?? []).compactMap { line -> BookLine? in
            guard let text = line.topCandidates(1).first?.string else { return nil }
            let rect = line.boundingBox
            return BookLine(text: text, bounds: CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                                                        width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)))
        }
        return bookParagraphs(from: lines).map(\.text).joined(separator: "\n\n")
    }

    public static func illustratedPage(_ page: PDFPage, englishOnly: Bool, correction: String? = nil) throws -> IllustratedPage {
        try Task.checkCancellation()
        guard let source = page.pageRef else { throw ReadingSyncError.invalidPDF }
        let raster = try ReadingPDFPageRaster(page: source, longEdge: 1000)
        let scanner = PDFImageRegions(raster.page)
        let pageArea = raster.canvas.width * raster.canvas.height
        let rawRegions = scanner?.scan() ?? []
        let regions = rawRegions.map { region in
            region.applying(raster.transform).intersection(raster.canvas)
        }.filter { region in
            !region.isEmpty && region.width >= raster.canvas.width * 0.055 && region.height >= raster.canvas.height * 0.035
        }
        // A nearly full-page background enclosing another illustration is not an illustration itself.
        var illustrations: [CGRect] = []
        for region in regions {
            let isBackground = region.width * region.height >= pageArea * 0.82 &&
                regions.contains { $0 != region && region.contains($0) }
            if !isBackground && !illustrations.contains(region) { illustrations.append(region) }
        }
        illustrations.sort { $0.maxY == $1.maxY ? $0.minX < $1.minX : $0.maxY > $1.maxY }

        let embedded = embeddedBookPage(page)
        var paragraphs = embedded?.paragraphs ?? []
        var body = embedded?.text ?? ""
        var usedOCR = false
        var images = illustrations
        let possibleScan = images.count == 1 && images[0].width * images[0].height >= pageArea * 0.82
        if let correction {
            body = correction
            paragraphs = []
            usedOCR = true
        } else if embedded == nil && (images.isEmpty || possibleScan) {
            body = try recognizedText(page, box: nil)
            usedOCR = !body.isEmpty
        }
        if possibleScan, !body.isEmpty { images = [] }
        if images.isEmpty, body.isEmpty { images = [raster.canvas] }

        if englishOnly {
            paragraphs = paragraphs.filter { ReadingPDFText.isEnglish($0.text) }
            body = ReadingPDFText.englishOnly(body)
        }
        let beforeCleanup = ReadingMaterial.normalizedBody(body)
        if !paragraphs.isEmpty {
            paragraphs = paragraphs.map { BookLine(text: cleanSpacing($0.text), bounds: $0.bounds) }
            body = paragraphs.map(\.text).joined(separator: "\n\n")
        } else if correction == nil, embedded != nil {
            body = body.components(separatedBy: "\n\n").map(cleanSpacing).joined(separator: "\n\n")
        }
        body = ReadingMaterial.normalizedBody(body)
        let content = body as NSString
        var offset = 0
        let placements = paragraphs.compactMap { paragraph -> (CGRect, Int)? in
            let length = paragraph.text.utf16.count
            let start = offset
            offset += length + 2
            guard length <= content.length - start,
                  content.substring(with: NSRange(location: start, length: length)) == paragraph.text else { return nil }
            return (paragraph.bounds.applying(raster.transform), start)
        }
        let figures = images.map { region in
            let overlapsText = placements.contains { bounds, _ in
                let overlap = bounds.intersection(region)
                return !overlap.isNull && overlap.width > 4 && overlap.height > 4
            }
            let uncertain = !body.isEmpty && (overlapsText || placements.count != paragraphs.count ||
                                             paragraphs.isEmpty || scanner?.incomplete == true)
            let position = placements.first { $0.0.maxY <= region.minY + 2 }?.1 ?? content.length
            let box = CGRect(x: region.minX / raster.canvas.width, y: 1 - region.maxY / raster.canvas.height,
                             width: region.width / raster.canvas.width, height: region.height / raster.canvas.height)
            return ReadingPDFFigure(offset: uncertain ? content.length : position, rect: box, inPageGallery: uncertain)
        }
        return IllustratedPage(text: body, usedOCR: usedOCR, normalizedText: beforeCleanup != body, figures: figures)
    }

    private static func cleanSpacing(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func embeddedBookPage(_ page: PDFPage) -> (text: String, paragraphs: [BookLine])? {
        guard let raw = page.string, raw.rangeOfCharacter(from: .alphanumerics) != nil,
              !raw.contains("\u{FFFD}") else { return nil }
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return (Self.reflow(raw), []) }
        let lines = selection.selectionsByLine().compactMap { line -> BookLine? in
            guard let text = line.string else { return nil }
            return BookLine(text: text, bounds: line.bounds(for: page))
        }
        // Scans can have a selectable page number or running header over a full-page image.
        let bounds = page.bounds(for: .cropBox)
        let interior = bounds.insetBy(dx: 0, dy: bounds.height * 0.10)
        if !lines.contains(where: { $0.bounds.intersects(interior) && $0.text.contains(where: \.isLetter) }) { return nil }
        let paragraphs = Self.bookParagraphs(from: lines)
        return paragraphs.isEmpty ? (Self.reflow(raw), []) : (paragraphs.map(\.text).joined(separator: "\n\n"), paragraphs)
    }

    private struct BookLine {
        var text: String
        var bounds: CGRect
    }

    private static func bookParagraphs(from fragments: [BookLine]) -> [BookLine] {
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
                if !text.isEmpty, !ReadingPDFText.containsChinese(part) { text += " " }
                text += part
            }
            let bounds = pieces.reduce(CGRect.null) { $0.union($1.bounds) }
            return BookLine(text: ReadingPDFText.normalizeLine(text), bounds: bounds)
        }
        let left = rows.map(\.bounds.minX).min() ?? 0
        var paragraphs: [BookLine] = []
        var previous: BookLine?
        for row in rows where !row.text.isEmpty {
            if let prior = previous, !paragraphs.isEmpty {
                let gap = prior.bounds.midY - row.bounds.midY
                let height = max(prior.bounds.height, row.bounds.height)
                let languageChanged = ReadingPDFText.containsChinese(prior.text) != ReadingPDFText.containsChinese(row.text)
                let indented = row.bounds.minX > left + max(10, height * 1.25)
                let followsHeading = paragraphs.count == 1 && paragraphs[0].text == prior.text
                    && ReadingPDFText.chapterNumber(in: prior.text) != nil
                let startsParagraph = followsHeading || languageChanged || indented || gap > height * 1.75
                if !startsParagraph {
                    paragraphs[paragraphs.count - 1].text += (ReadingPDFText.containsChinese(row.text) ? "" : " ") + row.text
                    paragraphs[paragraphs.count - 1].bounds = paragraphs[paragraphs.count - 1].bounds.union(row.bounds)
                } else {
                    paragraphs.append(row)
                }
            } else {
                paragraphs.append(row)
            }
            previous = row
        }
        return paragraphs
    }

    public static func reflow(_ text: String) -> String {
        let normalized = ReadingMaterial.normalizedBody(text)
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
