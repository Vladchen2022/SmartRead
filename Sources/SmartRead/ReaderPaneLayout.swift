import SwiftUI

struct ReaderPaneLayout {
    static let dividerWidth: CGFloat = 20
    static let defaultInspectorFraction = 0.38
    static let inspectorFractionRange = 0.0...0.68
    static let defaultBodyWidth = 0.72

    let inspectorWidth: CGFloat
    let articleWidth: CGFloat
    let articleContentWidth: CGFloat
    let articleWidthPercent: Int

    private let availableWidth: CGFloat

    init(windowWidth: CGFloat, inspectorFraction: Double, bodyWidth: Double, inspectorDelta: CGFloat = 0) {
        let available = max(0, windowWidth - Self.dividerWidth)
        availableWidth = available
        let widestInspector = max(0, min(available - 352, available * Self.inspectorFractionRange.upperBound))
        let narrowestInspector = min(280, widestInspector)
        let preferred = min(max(available * inspectorFraction, narrowestInspector), widestInspector)
        inspectorWidth = min(max(preferred + inspectorDelta, narrowestInspector), widestInspector)
        articleWidth = available - inspectorWidth

        let sideInset = min(32, max(16, articleWidth * 0.035))
        let usableArticle = max(0, articleWidth - sideInset * 2)
        let minimumBody = min(usableArticle, max(274, usableArticle * 0.5))
        articleContentWidth = (minimumBody + (usableArticle - minimumBody) * min(max(bodyWidth, 0), 1)).rounded(.down)
        articleWidthPercent = usableArticle > 0 ? Int((articleContentWidth / usableArticle * 100).rounded()) : 100
    }

    var inspectorFraction: Double {
        availableWidth > 0 ? inspectorWidth / availableWidth : Self.defaultInspectorFraction
    }
}

struct ReaderDivider: View {
    let isResizing: Bool
    @State private var isHovering = false

    var body: some View {
        let active = isResizing || isHovering
        ZStack {
            Rectangle()
                .fill(active ? ReaderPalette.accentFill : ReaderPalette.panel)
            Rectangle()
                .fill(active ? ReaderPalette.accent.opacity(0.45) : ReaderPalette.rule)
                .frame(width: 1)
            Capsule()
                .fill(active ? ReaderPalette.accent : ReaderPalette.muted.opacity(0.65))
                .frame(width: active ? 5 : 3, height: 44)
        }
        .frame(width: ReaderPaneLayout.dividerWidth)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("左右拖动，调整右侧助手的宽度")
    }
}

struct ReaderInspector<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer
    let scrollsContent: Bool

    init(scrollsContent: Bool = true, @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
        self.scrollsContent = scrollsContent
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(ReaderPalette.rule).frame(height: 1)
            if scrollsContent {
                ScrollView { content }
            } else {
                content
            }
            footer
        }
        .frame(maxHeight: .infinity)
        .background(ReaderPalette.panel)
    }
}

extension ReaderInspector where Footer == EmptyView {
    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content) { EmptyView() }
    }
}

struct ReaderInspectorHeading: View {
    let title: String
    let symbol: String
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 24 * scale, weight: .semibold))
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}
