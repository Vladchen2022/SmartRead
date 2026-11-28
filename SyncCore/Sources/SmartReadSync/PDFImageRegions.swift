import CoreGraphics

/// Walk only painting operations needed to locate embedded raster figures.
/// The original page is rendered for display so appearance, masks and color are preserved.
final class PDFImageRegions {
    private let page: CGPDFPage
    private let operators: CGPDFOperatorTableRef
    private var transform = CGAffineTransform.identity
    private var saved: [CGAffineTransform] = []
    private var ancestors: Set<CGPDFStreamRef> = []
    private var regions: [CGRect] = []
    private(set) var incomplete = false
    private var formsRemaining = 1000

    init?(_ page: CGPDFPage) {
        guard let operators = CGPDFOperatorTableCreate() else { return nil }
        self.page = page
        self.operators = operators
        CGPDFOperatorTableSetCallback(operators, "q") { _, info in
            guard let info else { return }
            let scan = Unmanaged<PDFImageRegions>.fromOpaque(info).takeUnretainedValue()
            scan.saved.append(scan.transform)
        }
        CGPDFOperatorTableSetCallback(operators, "Q") { _, info in
            guard let info else { return }
            let scan = Unmanaged<PDFImageRegions>.fromOpaque(info).takeUnretainedValue()
            if let previous = scan.saved.popLast() { scan.transform = previous }
        }
        CGPDFOperatorTableSetCallback(operators, "cm") { scanner, info in
            guard let info else { return }
            var a: CGFloat = 0, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 0, tx: CGFloat = 0, ty: CGFloat = 0
            guard CGPDFScannerPopNumber(scanner, &ty), CGPDFScannerPopNumber(scanner, &tx),
                  CGPDFScannerPopNumber(scanner, &d), CGPDFScannerPopNumber(scanner, &c),
                  CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &a) else { return }
            let scan = Unmanaged<PDFImageRegions>.fromOpaque(info).takeUnretainedValue()
            scan.transform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty).concatenating(scan.transform)
        }
        CGPDFOperatorTableSetCallback(operators, "Do") { scanner, info in
            guard let info else { return }
            Unmanaged<PDFImageRegions>.fromOpaque(info).takeUnretainedValue().paint(scanner)
        }
        CGPDFOperatorTableSetCallback(operators, "BI") { _, info in
            guard let info else { return }
            Unmanaged<PDFImageRegions>.fromOpaque(info).takeUnretainedValue().incomplete = true
        }
    }

    deinit { CGPDFOperatorTableRelease(operators) }

    func scan() -> [CGRect] {
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        scan(stream)
        return regions
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(stream, operators, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        if !CGPDFScannerScan(scanner) { incomplete = true }
    }

    private func paint(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { return }
        let parent = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
        var candidate: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &candidate), let stream = candidate,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var nameValue: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &nameValue), let nameValue else { return }
        switch String(cString: nameValue) {
        case "Image":
            var mask: CGPDFBoolean = 0
            if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &mask), mask != 0 { return }
            let bounds = CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform).standardized
            guard bounds.width >= 55, bounds.height >= 38, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.minX.isFinite, bounds.minY.isFinite else { return }
            if regions.count < 64 { regions.append(bounds) }
            else { incomplete = true }
        case "Form":
            guard ancestors.count < 12, !ancestors.contains(stream), formsRemaining > 0 else {
                incomplete = true
                return
            }
            formsRemaining -= 1
            var resources: CGPDFDictionaryRef?
            if !CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let pageDictionary = page.dictionary {
                _ = CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources)
            }
            guard let resources else { incomplete = true; return }
            let nested = CGPDFContentStreamCreateWithStream(stream, resources, parent)
            let prior = transform
            let stack = saved
            saved = []
            ancestors.insert(stream)
            defer {
                ancestors.remove(stream)
                saved = stack
                transform = prior
                CGPDFContentStreamRelease(nested)
            }
            var matrix: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix {
                var values = [CGFloat](repeating: 0, count: 6)
                if (0..<6).allSatisfy({ CGPDFArrayGetNumber(matrix, $0, &values[$0]) }) {
                    transform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3],
                                                  tx: values[4], ty: values[5]).concatenating(prior)
                }
            }
            scan(nested)
        default: break
        }
    }
}
