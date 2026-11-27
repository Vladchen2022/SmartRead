import XCTest
@testable import SmartRead

final class AssistantQuestionTests: XCTestCase {
    func testQuestionRequestSeparatesTheQuestionFromItsShortReferenceAndUsesOnlyRecentTurns() throws {
        let client = try LMStudioClient(endpoint: LMStudioClient.defaultEndpoint)
        let quote = AssistantQuestionReference(passage: "She looked it up.", focus: "looked it up", timestamp: "00:12",
            surrounding: SentenceContext(previousSentence: "She found an unknown word.", nextSentence: "Now she knew it."))
        let history = (0...4).map { AssistantQuestionTurn(question: "Question \($0)", answer: "Answer \($0)", isComplete: $0 < 4) }
        let request = AssistantQuestionRequest(question: "这里为什么把 it 放在中间？", reference: quote,
                                              includeSurrounding: false, history: history)
        let payload = try fields(client.makeQuestionRequest(request, model: "test-model"))
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        let system = try XCTUnwrap(messages.first?["content"])
        XCTAssertTrue(system.contains("只回答最后一条消息"))
        XCTAssertTrue(system.contains("默认用简体中文一至三句"))
        XCTAssertTrue(system.contains("与英语学习无关"))
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual(payload["max_tokens"] as? Int, 420)
        XCTAssertEqual(messages.count, 8)
        XCTAssertEqual(messages.dropFirst().first?["content"], "Question 1")
        XCTAssertEqual(messages.dropLast().last?["content"], "Answer 3")
        let last = try input(messages)
        XCTAssertEqual(last["question"] as? String, request.question)
        XCTAssertEqual(last["passage"] as? String, quote.passage)
        XCTAssertEqual(last["focus"] as? String, quote.focus)
        XCTAssertNil(last["timestamp"])
        XCTAssertNil(last["surrounding"])

        let withContext = AssistantQuestionRequest(question: request.question, reference: quote,
                                                   includeSurrounding: true, history: [])
        let related = try fields(client.makeQuestionRequest(withContext, model: "test-model"))
        let relatedMessages = try XCTUnwrap(related["messages"] as? [[String: String]])
        let context = try input(relatedMessages)["surrounding"] as? [String: String]
        XCTAssertEqual(context?["previousSentence"], "She found an unknown word.")
        let unrelated = AssistantQuestionRequest(question: "affect 和 effect 怎么区分？", reference: nil,
                                                includeSurrounding: false, history: [])
        let independent = try fields(client.makeQuestionRequest(unrelated, model: "test-model"))
        let independentMessages = try XCTUnwrap(independent["messages"] as? [[String: String]])
        XCTAssertEqual(try input(independentMessages) as? [String: String], ["question": unrelated.question])
    }

    func testEarlierQuestionPreservesItsOwnFocusedWord() throws {
        let passage = "She looked it up."
        let old = AssistantQuestionReference(passage: passage, focus: "looked")
        let current = AssistantQuestionReference(passage: passage, focus: "it")
        let turn = AssistantQuestionTurn(question: "这里怎么理解？", answer: "查找。", isComplete: true, reference: old)
        let request = AssistantQuestionRequest(question: "这里呢？", reference: current, includeSurrounding: false,
                                               history: [turn])
        let client = try LMStudioClient(endpoint: LMStudioClient.defaultEndpoint)
        let packet = try fields(client.makeQuestionRequest(request, model: "test"))
        let messages = try XCTUnwrap(packet["messages"] as? [[String: String]])
        let previous = try input(Array(messages.prefix(2)))
        XCTAssertEqual(previous["focus"] as? String, "looked")
        XCTAssertEqual(try input(messages)["focus"] as? String, "it")
    }

    @MainActor
    func testFollowupStaysWithItsSentenceAndRestoresPreviousTurns() async throws {
        let chat = AssistantQuestionChat()
        let original = AssistantQuestionReference(passage: "She looked it up.", focus: "looked it up", timestamp: "00:12")
        let current = AssistantQuestionReference(passage: "He wrote it down.", timestamp: "00:17")
        chat.selectReference(.init(reference: original))
        chat.draft = "这里是什么意思？"
        chat.send { request, update in
            XCTAssertEqual(request.reference, original)
            XCTAssertTrue(request.history.isEmpty)
            update("表示")
            XCTAssertEqual(chat.turns.last?.answer, "表示")
            return "表示查找信息。"
        }
        try await waitForReply(chat)
        XCTAssertEqual(chat.turns.last?.answer, "表示查找信息。")
        chat.selectReference(.init(reference: original))
        XCTAssertEqual(chat.turns.count, 1)
        chat.draft = "为什么把 it 放在中间？"
        chat.send { request, _ in
            XCTAssertEqual(request.reference, original)
            XCTAssertEqual(request.history.last?.answer, "表示查找信息。")
            return "代词作宾语时放在 look 和 up 之间。"
        }
        try await waitForReply(chat)
        chat.draft = "这里的 down 有什么用？"
        chat.selectReference(.init(reference: current))
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertEqual(chat.draft, "这里的 down 有什么用？")
        chat.send { request, _ in
            XCTAssertEqual(request.reference, current)
            XCTAssertTrue(request.history.isEmpty)
            return "write down 表示记下来。"
        }
        try await waitForReply(chat)
        XCTAssertEqual(chat.turns.count, 1)
        var differentFocus = original
        differentFocus.focus = "it"
        chat.selectReference(.init(reference: differentFocus))
        XCTAssertEqual(chat.reference, differentFocus)
        XCTAssertEqual(chat.turns.map(\.answer), ["表示查找信息。", "代词作宾语时放在 look 和 up 之间。"])
        XCTAssertEqual(chat.turns.last?.reference, original)

        let suggested = try XCTUnwrap(differentFocus.quickQuestions.first)
        XCTAssertTrue(suggested.contains("it"))
        XCTAssertEqual(current.quickQuestions.count, 2)
        XCTAssertNotEqual(current.quickQuestions, differentFocus.quickQuestions)
        chat.draft = "Draft"
        chat.insertQuestion(suggested)
        XCTAssertEqual(chat.draft, "Draft\n" + suggested)
        XCTAssertEqual(chat.turns.count, 2)
        chat.startNewConversation()
        XCTAssertTrue(chat.turns.isEmpty)
        chat.selectReference(.init(reference: current))
        XCTAssertEqual(chat.turns.first?.answer, "write down 表示记下来。")
    }

    @MainActor
    func testReopeningMaterialRestoresItsOwnSentenceAndCancelsInFlightResponse() async throws {
        let chat = AssistantQuestionChat()
        let line = "The same sentence."
        let first = AssistantQuestionReference(passage: line, source: textSource(material: "A", passage: line))
        let second = AssistantQuestionReference(passage: line, source: textSource(material: "B", passage: line))
        chat.activate(material: "A")
        chat.replaceReference(with: first)
        chat.draft = "Question A"
        chat.send { _, _ in "Answer A" }
        try await waitForReply(chat)
        chat.draft = "Question A2"
        chat.send { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return "Stopped answer"
        }
        chat.activate(material: "B")
        chat.replaceReference(with: second)
        XCTAssertTrue(chat.turns.isEmpty)
        XCTAssertTrue(chat.draft.isEmpty)
        chat.draft = "Question B"
        chat.send { _, _ in "Answer B" }
        try await waitForReply(chat)
        chat.activate(material: "A")
        chat.replaceReference(with: first)
        XCTAssertEqual(chat.turns.first?.answer, "Answer A")
        XCTAssertEqual(chat.turns.last?.question, "Question A2")
        XCTAssertEqual(chat.turns.last?.isComplete, false)
        XCTAssertTrue(chat.canRetry)
    }

    func testOnlyUniqueVerbatimQuotedTextBecomesClickable() throws {
        let passage = "She looked it up after saying no, then no again."
        let reference = AssistantQuestionReference(passage: passage, source: textSource(material: "A", passage: passage))
        let answer = "意思是找资料。`looked it up` 和“after saying”是原文。`look`、`no`、`Looked`、`made up`只是说明。"
        let linked = AssistantAnswerLinks(answer: answer, reference: reference)
        let text = try AttributedString(markdown: linked.markdown)
        let links = text.runs.compactMap(\.link)
        XCTAssertEqual(links.compactMap(linked.location), ["looked it up", "after saying"].map { (passage as NSString).range(of: $0) })
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(String(text.characters).contains("look、no、Looked、made up"))
    }

    @MainActor
    func testLinkedTextReopensTheOriginalArticleAndSelectsTheExactWords() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = ReaderModel(store: ArticleStore(root: root), learningStore: LearningRecordStore(projectRoot: root))
        let body = "I found an unknown word. Then I looked it up."
        let phrase = "looked it up"
        let range = (body as NSString).range(of: phrase)
        try reader.importText(body, title: "Original")
        reader.selectQuestionReference(.init(text: phrase, range: range, context: ""))
        let reference = try XCTUnwrap(reader.questionSelection?.reference)
        let excerpt = try XCTUnwrap(reference.linkRange(for: phrase))
        try reader.importText("A separate article.", title: "Other")
        try await reader.locateQuestionSource(reference, excerpt: excerpt)
        XCTAssertEqual(reader.article.title, "Original")
        XCTAssertEqual(reader.jump?.range, range)
        XCTAssertTrue(reader.jump?.select == true)
        XCTAssertNil(reference.sourceRange(in: "I found an unknown word. Then I looked it over.",
                                           at: (body as NSString).range(of: reference.passage), excerpt: excerpt))
    }

    @MainActor
    func testCompletedFavoritesFromAllModesPersistAndCanBeRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "question-favorites.json")
        let favorites = AssistantQuestionFavorites(file: path)
        let passage = "This is a sample."
        let range = NSRange(location: 0, length: passage.utf16.count)
        let video = root.appending(path: "sample.mp4")
        let sources: [AssistantQuestionSource] = [
            textSource(material: "text", passage: passage),
            .init(title: "Audio", location: .audio(entry: UUID(), cue: UUID(), range: range)),
            .init(title: "Video", location: .video(file: video, cues: [.init(start: 1_000, text: passage)]))
        ]
        try favorites.toggle(.init(question: "Incomplete"), mode: .text)
        XCTAssertTrue(favorites.entries.isEmpty)
        for source in sources {
            let reference = AssistantQuestionReference(passage: passage, source: source)
            let completed = AssistantQuestionTurn(question: "Question", answer: "Answer", isComplete: true, reference: reference)
            try favorites.toggle(completed, mode: source.mode)
            XCTAssertTrue(favorites.contains(completed.id))
        }
        let reopened = AssistantQuestionFavorites(file: path)
        XCTAssertEqual(reopened.entries, favorites.entries)
        XCTAssertEqual(reopened.entries.compactMap { $0.reference?.source }, Array(sources.reversed()))
        XCTAssertEqual(reopened.entries.compactMap { $0.reference?.passage }, Array(repeating: passage, count: 3))
        try reopened.remove(try XCTUnwrap(reopened.entries.first?.id))
        XCTAssertEqual(AssistantQuestionFavorites(file: path).entries.count, 2)
    }

    @MainActor
    func testAnswerFavoritesRequireTheTurnOriginalAndPreserveLegacyEntries() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "question-favorites.json")
        let legacy = AssistantQuestionFavorite(id: UUID(), question: "Old question", answer: "Old answer",
                                               reference: nil, mode: .text, savedAt: .now)
        try JSONEncoder().encode([legacy]).write(to: file)
        let favorites = AssistantQuestionFavorites(file: file)
        var turn = AssistantQuestionTurn(question: "Question", answer: "Answer", isComplete: true)
        XCTAssertThrowsError(try favorites.toggle(turn, mode: .text))
        turn.reference = .init(passage: "  \n")
        XCTAssertThrowsError(try favorites.toggle(turn, mode: .text))
        XCTAssertEqual(favorites.entries.map(\.id), [legacy.id])

        let original = "She looked it up in the dictionary."
        turn.reference = .init(passage: original, focus: "looked it up")
        try favorites.toggle(turn, mode: .video)
        let reopened = AssistantQuestionFavorites(file: file)
        XCTAssertEqual(reopened.entries.first?.reference?.passage, original)
        XCTAssertNil(reopened.entries.first?.reference?.source)
        XCTAssertEqual(reopened.entries.last?.id, legacy.id)
        try reopened.remove(legacy.id)
        XCTAssertEqual(reopened.entries.map(\.id), [turn.id])
    }

    func testPracticeRequestsSeparateTheExerciseFromItsFeedback() throws {
        let client = try LMStudioClient(endpoint: LMStudioClient.defaultEndpoint)
        let turn = AssistantQuestionTurn(question: "look up 的用法？", answer: "表示查阅。", isComplete: true,
                                         reference: .init(passage: "She looked it up.", focus: "looked it up"))
        let generation = AssistantPracticeRequest(turn: turn, step: .exercise)
        let review = AssistantPracticeRequest(turn: turn, step: .feedback(exercise: "用 look up 写一句。", response: "I looked up it."))
        let generated = try XCTUnwrap(fields(client.makePracticeRequest(generation, model: "test"))["messages"] as? [[String: String]])
        let reviewed = try XCTUnwrap(fields(client.makePracticeRequest(review, model: "test"))["messages"] as? [[String: String]])
        XCTAssertTrue(generated.first?["content"]?.contains("只给一道") == true)
        XCTAssertTrue(reviewed.first?["content"]?.contains("用一两句") == true)
        XCTAssertEqual(try input(generated)["passage"] as? String, turn.reference?.passage)
        XCTAssertNil(try input(generated)["response"])
        XCTAssertEqual(try input(reviewed)["exercise"] as? String, "用 look up 写一句。")
        XCTAssertEqual(try input(reviewed)["response"] as? String, "I looked up it.")
    }

    @MainActor
    func testTextReferenceUsesTheCompleteSentenceAndKeepsTheWordAsFocus() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = ReaderModel(store: ArticleStore(root: root), learningStore: LearningRecordStore(projectRoot: root))
        let body = "She found an unfamiliar word. She looked it up. Now she understood the story."
        try reader.importText(body, title: "Exercise")
        let focus = "looked it up"
        reader.selection = TextExcerpt(text: focus, range: (body as NSString).range(of: focus), context: "")
        let reference = try XCTUnwrap(reader.assistantQuestionReference(currentOnly: false, spoken: nil))
        XCTAssertEqual(reference.passage, "She looked it up.")
        XCTAssertEqual(reference.focus, focus)
        XCTAssertEqual(reference.surrounding?.previousSentence, "She found an unfamiliar word.")
        reader.selectQuestionReference(try XCTUnwrap(reader.selection))
        let selected = reader.questionSelection
        reader.selection = nil
        XCTAssertNil(reader.assistantQuestionReference(currentOnly: false, spoken: nil))
        XCTAssertEqual(reader.questionSelection, selected)
        let next = "Now she understood the story."
        XCTAssertTrue(reader.clickText(at: (body as NSString).range(of: next).location, wholeSentence: true))
        defer { reader.cancelLookup() }
        XCTAssertEqual(reader.questionSelection?.reference.passage, next)
        XCTAssertNil(reader.questionSelection?.reference.focus)
        XCTAssertEqual(reader.assistantTranslation?.excerpt.text, next)
        XCTAssertNil(reader.translationAnalysis)

        XCTAssertTrue(reader.clickText(at: (body as NSString).range(of: "looked").location, wholeSentence: false))
        XCTAssertEqual(reader.lookup?.kind, .word)
        XCTAssertEqual(reader.assistantTranslation?.excerpt.text, "She looked it up.")
        XCTAssertEqual(reader.assistantTranslation?.surrounding?.nextSentence, next)
        XCTAssertNil(reader.translationAnalysis)
        XCTAssertEqual(reader.questionSelection?.reference.focus, "looked")
        try reader.importText("The lesson is over.", title: "Another exercise")
        XCTAssertNil(reader.assistantTranslation)
        XCTAssertNil(reader.wordTranslation.result.completedText)
    }

    @MainActor
    func testSelectingPartOfASentenceUsesTheWholeSentenceForPreviewAndFavorite() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = ReaderModel(store: ArticleStore(root: root), learningStore: LearningRecordStore(projectRoot: root))
        let body = "The door opened. We spoke briefly."
        try reader.importText(body, title: "Preview")
        XCTAssertNil(reader.selectedPreviewSentence)
        let text = "briefly"
        reader.selection = TextExcerpt(text: text, range: (body as NSString).range(of: text), context: "")
        let preview = try XCTUnwrap(reader.selectedPreviewSentence)
        XCTAssertEqual(preview.text, "We spoke briefly.")
        XCTAssertEqual(reader.sentenceFavoriteExcerpt, preview)
        XCTAssertFalse(reader.isSentenceFavorite(preview))
    }

    @MainActor
    func testSentenceFavoriteUpgradesAnOriginalAndKeepsGrammarSeparate() async throws {
        guard let model = ProcessInfo.processInfo.environment["SMARTREAD_TEST_QUESTION_MODEL"] else {
            throw XCTSkip("Set SMARTREAD_TEST_QUESTION_MODEL to a loaded LM Studio model")
        }
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "SmartReadTests.SentenceFavorite.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = ArticleStore(root: root)
        let reader = ReaderModel(defaults: defaults, store: store, learningStore: LearningRecordStore(projectRoot: root))
        reader.preferredModel = model
        try reader.importText("We put the book on the table. The room was quiet.", title: "Favorite")
        let sentence = try XCTUnwrap(reader.articleForListening(fromHere: false).sentences.first)
        try reader.saveFavorite(.init(kind: .originalSentence, excerpt: sentence, result: .init()))
        try reader.saveFavorite(.init(kind: .grammar, excerpt: sentence, result: .init(analysis: "过去式")))
        try await reader.toggleSentenceFavorite(sentence)

        let saved = try XCTUnwrap(reader.favorites.first { $0.favorite.kind == .sentence }?.favorite)
        XCTAssertEqual(saved.selectedText, sentence.text)
        let translation = try XCTUnwrap(saved.result.translation)
        XCTAssertTrue(translation.contains("书"), translation)
        XCTAssertNil(saved.result.analysis)
        XCTAssertEqual(reader.favoriteCount, 2)
        XCTAssertTrue(reader.isSentenceFavorite(sentence))

        let reopened = ReaderModel(defaults: defaults, store: store, learningStore: LearningRecordStore(projectRoot: root))
        XCTAssertTrue(reopened.isSentenceFavorite(sentence))
        try await reopened.toggleSentenceFavorite(sentence)
        XCTAssertFalse(reopened.isSentenceFavorite(sentence))
        XCTAssertEqual(reopened.favorites.map(\.favorite.kind), [.grammar])
    }

    func testActualLocalModelAnswersBrieflyAndStaysOnTopicWhenConfigured() async throws {
        guard let model = ProcessInfo.processInfo.environment["SMARTREAD_TEST_QUESTION_MODEL"] else {
            throw XCTSkip("Set SMARTREAD_TEST_QUESTION_MODEL to a loaded LM Studio model")
        }
        let client = try LMStudioClient(endpoint: LMStudioClient.defaultEndpoint)
        let reference = AssistantQuestionReference(passage: "She looked it up in the dictionary.", focus: "looked it up")
        let first = AssistantQuestionRequest(question: "这里的 look up 是什么意思？", reference: reference,
                                             includeSurrounding: false, history: [])
        let answer = try await client.answer(first, model: model) { _ in }
        XCTAssertTrue(["查找", "查阅", "查词", "查询", "查"].contains(where: answer.contains))
        XCTAssertFalse(answer.contains("代词"), answer)
        XCTAssertLessThan(answer.count, 220)
        let next = AssistantQuestionRequest(question: "这里为什么把 it 放中间？", reference: reference,
                                            includeSurrounding: false,
                                            history: [.init(question: first.question, answer: answer, isComplete: true)])
        let followup = try await client.answer(next, model: model) { _ in }
        XCTAssertTrue(followup.contains("代词"))
        XCTAssertLessThan(followup.count, 240)
        let abbreviation = AssistantQuestionRequest(question: "这里的 1st 是什么意思？",
            reference: .init(passage: "And how do you spell your 1st name?", timestamp: "0:19"),
            includeSurrounding: false, history: [])
        let expanded = try await client.answer(abbreviation, model: model) { _ in }
        XCTAssertTrue(expanded.contains("first") && expanded.contains("第一"), expanded)
        XCTAssertFalse(expanded.contains("名字") || expanded.contains("字母"), expanded)
        let offTopic = AssistantQuestionRequest(question: "给我五条清洁烤箱的操作步骤。", reference: reference,
                                               includeSurrounding: false, history: [])
        let redirect = try await client.answer(offTopic, model: model) { _ in }
        XCTAssertEqual(redirect, "请问一个与英语学习有关的问题。")
        XCTAssertLessThan(redirect.count, 100)
        print("Local model samples: \(answer) | \(followup) | \(expanded) | \(redirect)")
    }

    private func fields(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func textSource(material: String, passage: String) -> AssistantQuestionSource {
        .init(title: "Article", location: .text(material: material,
            range: NSRange(location: 0, length: passage.utf16.count), pdf: nil))
    }

    private func input(_ messages: [[String: String]]) throws -> [String: Any] {
        let content = try XCTUnwrap(messages.last?["content"])
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    @MainActor
    private func waitForReply(_ chat: AssistantQuestionChat) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while chat.isGenerating && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.isGenerating)
        XCTAssertNil(chat.error)
    }
}
