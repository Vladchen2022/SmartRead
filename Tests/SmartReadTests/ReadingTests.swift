import XCTest
@testable import SmartRead

final class ReadingTests: XCTestCase {
    func testWindowAndDividerLeaveSpaceForBothPanes() {
        let wide = ReaderPaneLayout(windowWidth: 2_016, inspectorFraction: 0.38, bodyWidth: 1)
        XCTAssertGreaterThan(wide.inspectorWidth, 700)
        XCTAssertGreaterThan(wide.articleContentWidth, 1_000)
        XCTAssertEqual(wide.articleWidthPercent, 100)

        let compact = ReaderPaneLayout(windowWidth: 760, inspectorFraction: 0.68,
                                       bodyWidth: 0, inspectorDelta: 300)
        XCTAssertGreaterThanOrEqual(compact.articleWidth, 352)
        XCTAssertGreaterThan(compact.articleContentWidth, SelectionActionPlacement.wordSize.width + 16)
        XCTAssertEqual(compact.articleWidth + compact.inspectorWidth + ReaderPaneLayout.dividerWidth, 760)

        let retreated = ReaderPaneLayout(windowWidth: 760, inspectorFraction: 0.68,
                                         bodyWidth: 0, inspectorDelta: -20)
        XCTAssertEqual(retreated.inspectorWidth, compact.inspectorWidth - 20)
    }

    func testSelectionActionsStayInsideViewportNearTheActiveEnd() throws {
        let viewport = CGRect(x: 0, y: 0, width: 440, height: 340)
        let bottom = CGRect(x: 216, y: 292, width: 222, height: 37)
        let bottomActions = try XCTUnwrap(
            SelectionActionPlacement.frame(near: [bottom], in: viewport, prefersStart: false,
                                           size: SelectionActionPlacement.wordSize)
        )
        XCTAssertTrue(viewport.contains(bottomActions))
        XCTAssertLessThanOrEqual(bottomActions.maxY, bottom.minY)

        let first = CGRect(x: 26, y: 104, width: 390, height: 32)
        let last = CGRect(x: 10, y: 140, width: 310, height: 32)
        let backwardsActions = try XCTUnwrap(
            SelectionActionPlacement.frame(near: [first, last], in: viewport, prefersStart: true,
                                           size: SelectionActionPlacement.selectionSize)
        )
        XCTAssertTrue(viewport.contains(backwardsActions))
        XCTAssertLessThanOrEqual(backwardsActions.maxY, first.minY)
        XCTAssertEqual(backwardsActions.size, SelectionActionPlacement.selectionSize)
        XCTAssertNil(SelectionActionPlacement.frame(near: [], in: viewport, prefersStart: false,
                                                    size: SelectionActionPlacement.selectionSize))
    }

    func testChatRequestsDisableThinkingAndStreamTheAnswer() throws {
        let client = try LMStudioClient(endpoint: LMStudioClient.defaultEndpoint)
        let excerpt = TextExcerpt(text: "The river rose.", range: NSRange(location: 0, length: 15), context: "")

        for kind in [LookupKind.word, .translation, .analysis] {
            let lookup = LookupRequest(kind: kind, excerpt: excerpt)
            let request = try client.makeChatRequest(lookup, model: "test-model")
            let body = try XCTUnwrap(request.httpBody)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(fields["reasoning_effort"] as? String, "none", kind.rawValue)
            XCTAssertEqual(fields["stream"] as? Bool, true, kind.rawValue)
        }

        let lookup = LookupRequest(kind: .translation, excerpt: excerpt)
        let legacy = try client.makeChatRequest(lookup, model: "test-model", reasoningEffort: nil)
        let body = try XCTUnwrap(legacy.httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(fields["reasoning_effort"])
    }

    func testWordLookupMarksTheExactOccurrence() throws {
        let text = "🛶 The bank across from the bank’s new office floods every spring. The bank plans to move."
        let range = (text as NSString).range(of: "bank’s")
        let excerpt = try XCTUnwrap(WordLookup.excerpt(at: range.location + 4, in: text))
        XCTAssertEqual(excerpt.text, "bank’s")
        XCTAssertEqual(excerpt.markedContext, "🛶 The bank across from the ⟦bank’s⟧ new office floods every spring.")
        let space = (text as NSString).range(of: " ")
        XCTAssertNil(WordLookup.excerpt(at: space.location, in: text))
    }

    @MainActor
    func testXArticleUsesBodyAndRejectsTitleOnly() async throws {
        let parser = try HTMLExtractor()
        let url = URL(string: "https://x.com/example/status/1")!
        let article = try await parser.extract("""
        <html><head><meta property="og:description" content="A long read"></head><body>
        <h1>A long read</h1><nav>Navigation</nav>
        <div data-article-body-html=""><p>The first <em>paragraph</em> belongs here.</p>
        <p>The last paragraph belongs here too.</p></div><footer>Sign up</footer>
        </body></html>
        """, url: url, mode: "x")
        XCTAssertEqual(article?.title, "A long read")
        XCTAssertEqual(article?.body, "The first paragraph belongs here.\n\nThe last paragraph belongs here too.")
        let preview = try await parser.extract("<h1>A long read</h1><p>Please sign in</p>", url: url, mode: "x")
        XCTAssertNil(preview)
    }

    @MainActor
    func testWebArticlePreservesParagraphsAndDropsNavigation() async throws {
        let parser = try HTMLExtractor()
        let paragraph = "The weather forecast promised a dry Saturday, so Nora took the long way to the library and stopped by the river along the way."
        let article = try await parser.extract("""
        <html><head><title>At the Library</title></head><body><nav>Login or subscribe</nav>
        <article><h1>At the Library</h1><p>\(paragraph)</p><p>\(paragraph)</p></article>
        </body></html>
        """, url: URL(string: "https://example.com/reading")!, mode: "web")
        XCTAssertEqual(article?.title, "At the Library")
        XCTAssertEqual(article?.body, "\(paragraph)\n\n\(paragraph)")
    }
}
