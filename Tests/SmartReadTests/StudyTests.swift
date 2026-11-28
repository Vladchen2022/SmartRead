import XCTest
@testable import SmartRead

final class StudyTests: XCTestCase {
    @MainActor
    func testListeningFromSelectionUsesTheCorrectRepeatedSentenceAndOnlyOriginalText() throws {
        let body = "🛶 It rained again. She took an umbrella.\n\nIt rained again. The river rose."
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        try store.save(ArticleLibrary(current: try Article(title: "Listening fixture", body: body)))
        let reader = ReaderModel(store: store)
        let range = (body as NSString).range(of: "It rained again.", options: .backwards)
        reader.selection = TextExcerpt(text: "It rained again.", range: range, context: "")

        let plan = reader.articleForListening(fromHere: true)
        XCTAssertEqual(reader.articleForListening(fromHere: false).start, 0)
        XCTAssertEqual(plan.sentences[plan.start].range, range)
        XCTAssertEqual(plan.sentences.suffix(2).map(\.text), ["It rained again.", "The river rose."])
        let selected = reader.sentencesForListening(to: try XCTUnwrap(reader.selection))
        XCTAssertEqual(selected.map(\.range), [range])
        let continuation = reader.listeningContinuation(after: try XCTUnwrap(selected.last))
        XCTAssertEqual(continuation.map(\.text), ["The river rose."])
        XCTAssertTrue(reader.listeningContinuation(after: try XCTUnwrap(continuation.last)).isEmpty)
    }

    @MainActor
    func testLookingUpWholeSentenceSelectsAndTranslatesIt() throws {
        let sentence = "Since November 2022, we have been optimistic about AI, calling it a major technological shift."
        let body = "The previous paragraph sets the scene.\n\n\(sentence) Our view has evolved."
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArticleStore(root: root)
        try store.save(ArticleLibrary(current: try Article(title: "Reading fixture", body: body)))
        let reader = ReaderModel(store: store)
        defer { reader.cancelLookup() }
        let wordIndex = (body as NSString).range(of: "have").location
        let word = try XCTUnwrap(WordLookup.excerpt(at: wordIndex, in: body))
        reader.lookup = LookupRequest(kind: .word, excerpt: word)
        reader.answer = "一直\n搭配：have been｜一直处于"
        XCTAssertEqual(reader.marks, [ReaderMark(range: (body as NSString).range(of: "have been"), style: .phrase)])

        reader.translateSentence(containing: word)
        let selection = try XCTUnwrap(reader.selection)
        XCTAssertEqual(selection.text, sentence)
        XCTAssertEqual(selection.range, (body as NSString).range(of: sentence))
        XCTAssertEqual(reader.jump?.range, selection.range)
        XCTAssertEqual(reader.jump?.select, true)
        XCTAssertEqual(reader.lookup, LookupRequest(kind: .translation, excerpt: selection,
            surrounding: SentenceContext(previousSentence: "The previous paragraph sets the scene.",
                                         nextSentence: "Our view has evolved.")))
        XCTAssertTrue(reader.isLookingUp)
        XCTAssertTrue(reader.answer.isEmpty)
        XCTAssertTrue(reader.marks.isEmpty)
    }

    @MainActor
    func testOneClickUsesTheActiveReadingMode() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = ReaderModel(store: ArticleStore(root: root), learningStore: LearningRecordStore(projectRoot: root))
        defer { reader.cancelLookup() }
        let target = "I wrote Mei and put the card in front of me."
        let body = "“Write the name you want us to use,” she said. \(target) Then I waited."
        try reader.importText(body, title: "Call Me River")
        let position = (body as NSString).range(of: "Mei").location
        reader.clickText(at: position, wholeSentence: true)
        let lookup = try XCTUnwrap(reader.lookup)
        XCTAssertEqual(lookup.kind, .translation)
        XCTAssertEqual(lookup.excerpt.text, target)
        XCTAssertEqual(lookup.surrounding?.previousSentence, "“Write the name you want us to use,” she said.")
        XCTAssertEqual(lookup.surrounding?.nextSentence, "Then I waited.")
        XCTAssertEqual(reader.selection, lookup.excerpt)

        let client = try LMStudioClient(endpoint: LMStudioClient.defaultEndpoint)
        let payload = try XCTUnwrap(try client.makeChatRequest(lookup, model: "fixture").httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(fields["messages"] as? [[String: String]])
        let input = try XCTUnwrap(messages.last?["content"])
        let prompt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(prompt["text"] as? String, target)
        XCTAssertEqual((prompt["surrounding"] as? [String: String])?["previousSentence"],
                       "“Write the name you want us to use,” she said.")

        reader.selection = nil
        reader.clickText(at: position, wholeSentence: false)
        XCTAssertEqual(reader.lookup?.kind, .word)
        XCTAssertEqual(reader.lookup?.excerpt.text, "Mei")
        XCTAssertEqual(reader.assistantSource?.text, target)
        let phrase = try XCTUnwrap(reader.shortPhrase(in: (body as NSString).range(of: "the card in front")))
        XCTAssertEqual(phrase.markedContext, "I wrote Mei and put ⟦the card in front⟧ of me.")
        XCTAssertNil(reader.shortPhrase(in: (body as NSString).range(of: "of me. Then")))
    }

    @MainActor
    func testGrammarExpandsForTheDisplayedTranslationAndKeepsItsState() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let reader = ReaderModel(store: ArticleStore(root: root))
        defer {
            reader.stopTranslationAnalysis()
            reader.cancelLookup()
        }
        let excerpt = TextExcerpt(text: "I wrote Mei.", range: NSRange(location: 0, length: 12), context: "")
        let other = TextExcerpt(text: "She wrote River.", range: NSRange(location: 13, length: 16), context: "")
        let translation = LookupRequest(kind: .translation, excerpt: excerpt)
        reader.lookup = translation
        reader.answer = "我写下了梅的名字。"
        reader.selection = other

        reader.toggleTranslationAnalysis(for: translation)
        let analysis = try XCTUnwrap(reader.translationAnalysis)
        XCTAssertEqual(analysis.excerpt, excerpt)
        XCTAssertTrue(analysis.isExpanded)

        reader.toggleTranslationAnalysis(for: translation)
        XCTAssertEqual(reader.translationAnalysis?.isExpanded, false)
        reader.toggleTranslationAnalysis(for: translation)
        XCTAssertEqual(reader.translationAnalysis?.id, analysis.id)
        XCTAssertEqual(reader.translationAnalysis?.isExpanded, true)
        XCTAssertEqual(reader.lookup, translation)
        XCTAssertEqual(reader.answer, "我写下了梅的名字。")

        reader.lookUp(.translation)
        XCTAssertNil(reader.translationAnalysis)
        XCTAssertEqual(reader.lookup?.excerpt, other)
    }

    func testOutlineAnchorsMainVerbAndRejectsInventedQuote() throws {
        let text = "🛶 The point is that this is still an open question."
        let request = try ReadingIndex(text).request(.structure, at: 6)
        let reply = StudyReply(overview: "", items: [
            .init(role: "subject", source: "S1", quote: "The point", text: "主语", occurrence: 1),
            .init(role: "predicate", source: "S1", quote: "is", text: "谓语", occurrence: 1),
            .init(role: "clause", source: "S1", quote: "that this is still an open question", text: "从句", occurrence: 1),
            .init(role: "modifier", source: "S1", quote: "the missing clause", text: "模型编造", occurrence: 1)
        ], question: "", answer: "")
        let result = try reply.validated(for: request)
        XCTAssertEqual(result.items.map(\.style), [.subject, .predicate, .clause])
        XCTAssertEqual(result.items[1].range, (text as NSString).range(of: "is"))
        XCTAssertNil(StudyReply.find("is", in: request.target))
        XCTAssertNil(StudyReply.find("h", in: request.target))
    }

    func testCompactGrammarKeepsTheMainPartsAndOneGroundedDifficulty() throws {
        let text = "She put up with the noise because he was tired."
        var request = try ReadingIndex(text).request(.structure, at: 0)
        request.compactStructure = true
        let reply = StudyReply(overview: "她忍受了噪音。", items: [
            .init(role: "subject", source: "S1", quote: "She", text: "谁", occurrence: 1),
            .init(role: "predicate", source: "S1", quote: "put", text: "做什么", occurrence: 1),
            .init(role: "modifier", source: "S1", quote: "invented", text: "无原文", occurrence: 1),
            .init(role: "clause", source: "S1", quote: "because he was tired", text: "解释原因", occurrence: 1),
            .init(role: "referring", source: "S1", quote: "he", text: "另一处", occurrence: 1)
        ], question: "", answer: "")
        let result = try reply.validated(for: request)
        XCTAssertEqual(result.items.map(\.style), [.subject, .predicate, .clause])
        XCTAssertEqual(result.items.map(\.quote), ["She", "put", "because he was tired"])
    }

    func testReferenceUsesExactPreviousParagraphAndSelectedOccurrence() throws {
        let text = "The river rose overnight.\n\nThis surprised Nora. This worried her neighbors."
        let position = (text as NSString).range(of: "This worried").location
        let word = try XCTUnwrap(WordLookup.excerpt(at: position, in: text))
        let request = try ReadingIndex(text).request(.reference, at: position, word: word)
        let reply = StudyReply(overview: "", items: [
            .init(role: "referring", source: "S2", quote: "This", text: "指代", occurrence: 2),
            .init(role: "referent", source: "S1", quote: "The river rose overnight.", text: "", occurrence: 1)
        ], question: "", answer: "")
        let result = try reply.validated(for: request)
        XCTAssertEqual(result.items.map(\.style), [.referring, .referent])
        XCTAssertEqual(result.items[0].range, word.range)
        XCTAssertEqual(result.items[1].range.location, 0)
    }

    func testRewriteDoesNotPresentChangedNumbersAsAlignedText() throws {
        let text = "The bank expects a 25% cut. It may happen in 2026."
        let request = try ReadingIndex(text).request(.simpler, at: 0)
        XCTAssertEqual(request.sources.count, 2)
        let reply = StudyReply(overview: "", items: [
            .init(role: "rewrite", source: "S1", quote: "", text: "The bank expects a 50% cut.", occurrence: 1),
            .init(role: "rewrite", source: "S2", quote: "", text: "It might happen in 2026.", occurrence: 1)
        ], question: "", answer: "")
        let result = try reply.validated(for: request)
        XCTAssertEqual(result.items.map(\.quote), ["It may happen in 2026."])
        XCTAssertNotNil(result.note)
    }

    func testInlineTranslationPreservesOriginalOffsets() {
        let translation = InlineTranslation(sentence: NSRange(location: 0, length: 12), text: "例句。")
        let first = NSRange(location: 0, length: 12)
        let second = NSRange(location: 12, length: 7)
        let map = ReaderDisplayMap([(translation.insertion, translation.displayLength)])
        XCTAssertEqual(map.displayedRange(for: first), first)
        XCTAssertEqual(map.sourceRange(for: map.displayedRange(for: second)), second)
        XCTAssertNil(map.sourceCharacter(at: translation.closeRange.location))
        let across = NSRange(location: 6, length: 12)
        XCTAssertEqual(map.sourceRange(for: map.displayedRange(for: across)), across)
        XCTAssertEqual(map.displayedSegments(for: across).map(\.length), [6, 6])
    }
}
