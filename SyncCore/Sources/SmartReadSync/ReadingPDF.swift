import CoreGraphics
import Foundation

/// Offsets refer to UTF-16 positions in ReadingMaterial.body. Rectangles use
/// normalized coordinates from the top-left of the rotated PDF crop box.
public struct ReadingPDFFigure: Codable, Equatable, Sendable {
    public let offset: Int
    public let rect: CGRect
    public let inPageGallery: Bool

    public init(offset: Int, rect: CGRect, inPageGallery: Bool = false) {
        self.offset = offset
        self.rect = rect
        self.inPageGallery = inPageGallery
    }

    public var hasValidRect: Bool {
        rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1.000_001 && rect.maxY <= 1.000_001
            && rect.width > 0 && rect.height > 0
    }
}

public struct ReadingPDFPage: Codable, Equatable, Sendable {
    public let pageCount: Int
    public let figures: [ReadingPDFFigure]
    public let normalizedText: Bool?

    public init(pageCount: Int, figures: [ReadingPDFFigure], normalizedText: Bool? = nil) {
        self.pageCount = pageCount
        self.figures = figures
        self.normalizedText = normalizedText
    }

    public static func isValidBookID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func legacyKey(bookID: String, index: Int, englishOnly: Bool, normalized: Bool) -> String {
        let normalization = normalized ? ":clean" : ""
        return "pdf:\(bookID):\(index)\(normalization):\(englishOnly ? "en" : "all")"
    }
}

public struct ReadingPDFPageRaster {
    public let page: CGPDFPage
    public let canvas: CGRect
    public let transform: CGAffineTransform

    public init(page: CGPDFPage, longEdge: CGFloat) throws {
        let crop = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        guard !crop.isEmpty, crop.width.isFinite, crop.height.isFinite,
              longEdge.isFinite, (1...6000).contains(longEdge) else {
            throw ReadingSyncError.invalidPDF
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

    public func canvasRect(for box: CGRect) -> CGRect {
        CGRect(x: box.minX * canvas.width, y: (1 - box.maxY) * canvas.height,
               width: box.width * canvas.width, height: box.height * canvas.height)
    }

    public func image(in box: CGRect? = nil) throws -> CGImage {
        if let box, !ReadingPDFFigure(offset: 0, rect: box).hasValidRect { throw ReadingSyncError.invalidPDF }
        let slice = box.map { canvasRect(for: $0).integral.intersection(canvas) } ?? canvas
        guard !slice.isEmpty,
              let context = CGContext(data: nil, width: Int(slice.width), height: Int(slice.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ReadingSyncError.invalidPDF
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: slice.size))
        context.translateBy(x: -slice.minX, y: -slice.minY)
        context.concatenate(transform)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ReadingSyncError.invalidPDF }
        return image
    }
}
