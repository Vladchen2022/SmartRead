import SwiftUI

enum SelectionActionPlacement {
    static let wordSize = CGSize(width: 256, height: 56)
    static let selectionSize = CGSize(width: 225, height: 56)

    static func size(forWord: Bool, hasLanguageActions: Bool = true, hasMark: Bool = false, scale: CGFloat) -> CGSize {
        let languageWidth = hasLanguageActions ? (forWord ? wordSize.width : selectionSize.width) : 52
        let width = languageWidth + (hasMark ? 106 : 0)
        return CGSize(width: width * scale, height: selectionSize.height * scale)
    }

    static func frame(near lines: [CGRect], in viewport: CGRect, prefersStart: Bool, size: CGSize) -> CGRect? {
        let bounds = viewport.insetBy(dx: 8, dy: 8)
        guard bounds.width >= size.width, bounds.height >= size.height,
              let first = lines.first, let last = lines.last else { return nil }

        let anchor = prefersStart ? first : last
        let gap: CGFloat = 8
        let edge = prefersStart ? anchor.minX : anchor.maxX
        let x = clamp(edge - size.width / 2, to: bounds.minX...(bounds.maxX - size.width))
        let y = clamp(anchor.midY - size.height / 2, to: bounds.minY...(bounds.maxY - size.height))
        let above = CGRect(origin: CGPoint(x: x, y: first.minY - gap - size.height), size: size)
        let below = CGRect(origin: CGPoint(x: x, y: last.maxY + gap), size: size)
        let left = CGRect(origin: CGPoint(x: anchor.minX - gap - size.width, y: y), size: size)
        let right = CGRect(origin: CGPoint(x: anchor.maxX + gap, y: y), size: size)
        let preferences = prefersStart ? [above, below, left, right] : [below, above, right, left]
        let inside = preferences.filter { bounds.contains($0) }

        // If the selection spans the whole viewport, keep the toolbar close to the active end.
        let candidates = inside.isEmpty ? preferences.prefix(2).map {
            CGRect(origin: CGPoint(x: x, y: clamp($0.minY, to: bounds.minY...(bounds.maxY - size.height))), size: size)
        } : inside
        return candidates.min { coveredArea($0, in: lines) < coveredArea($1, in: lines) }
    }

    private static func coveredArea(_ frame: CGRect, in lines: [CGRect]) -> CGFloat {
        lines.reduce(0) { area, line in
            let overlap = frame.intersection(line)
            return area + (overlap.isNull ? 0 : overlap.width * overlap.height)
        }
    }

    private static func clamp(_ value: CGFloat, to limits: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, limits.lowerBound), limits.upperBound)
    }
}

struct SelectionActions: View {
    var wordAction: WordAction?
    let hasLanguageActions: Bool
    var cancelMark: (() -> Void)?
    let scale: CGFloat
    let translation: () -> Void
    let speak: () -> Void
    let translateSentence: () -> Void
    let wordStudy: (StudyKind) -> Void
    let close: () -> Void

    struct WordAction: Equatable {
        let excerpt: TextExcerpt
        let study: StudyKind
    }

    var body: some View {
        let size = SelectionActionPlacement.size(forWord: wordAction != nil, hasLanguageActions: hasLanguageActions,
                                                 hasMark: cancelMark != nil, scale: scale)
        HStack(spacing: 5 * scale) {
            if hasLanguageActions, let wordAction {
                button("看整句", symbol: "text.cursor", identifier: "wordAction-sentence", prominent: true,
                       help: "选中整句并在右侧显示译文", action: translateSentence)
                button(wordAction.study == .reference ? "看指代" : "看搭配",
                       symbol: wordAction.study.symbol, identifier: "wordAction-study", prominent: false,
                       help: wordAction.study.label) { wordStudy(wordAction.study) }
            } else if hasLanguageActions {
                button("翻译", symbol: LookupKind.translation.symbol, identifier: "selectionAction-translation",
                       prominent: true, help: "翻译选区（⇧⌘T）", action: translation)
                button("试听", symbol: "speaker.wave.2", identifier: "selectionAction-speak",
                       prominent: false, help: "临时朗读选中句子（普通阅读时按空格）", action: speak)
            }
            if let cancelMark {
                button("取消标记", symbol: "bookmark.slash", identifier: "selectionAction-cancelMark",
                       prominent: false, help: "取消这句的听力标记", action: cancelMark)
                    .frame(width: 101 * scale)
            }
            iconButton("关闭浮窗", symbol: "xmark", identifier: "readingActions-close", action: close)
        }
        .padding(6 * scale)
        .frame(width: size.width, height: size.height)
        .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 11 * scale))
        .overlay {
            RoundedRectangle(cornerRadius: 11 * scale).strokeBorder(ReaderPalette.accent.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.20), radius: 8, x: 0, y: 3)
    }

    private func iconButton(_ title: String, symbol: String, identifier: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(ReaderPalette.ink)
                .frame(width: 40 * scale, height: 44 * scale)
                .background(ReaderPalette.panel, in: RoundedRectangle(cornerRadius: 7 * scale))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .help(title)
    }

    private func button(_ title: String, symbol: String, identifier: String, prominent: Bool, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4 * scale) {
                Image(systemName: symbol)
                Text(title)
            }
                .font(.system(size: 15 * scale, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(prominent ? ReaderPalette.accent : ReaderPalette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 44 * scale)
                .background(
                    prominent ? ReaderPalette.accentFill : ReaderPalette.panel,
                    in: RoundedRectangle(cornerRadius: 7 * scale)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .help(help)
    }
}
