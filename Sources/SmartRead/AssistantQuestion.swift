import Foundation
import Observation

struct AssistantQuestionReference: Codable, Equatable {
    let passage: String
    var focus: String?
    var timestamp: String?
    var surrounding: SentenceContext?
    var source: AssistantQuestionSource?

    var hasSurrounding: Bool {
        surrounding?.previousSentence != nil || surrounding?.nextSentence != nil
    }

    var quickQuestions: [String] {
        if let focus, focus.count <= 60 {
            return ["这里的 \(focus) 能换成什么？", "这里为什么要用 \(focus)？"]
        }
        return ["这里为什么用这个时态？", "这句话更口语一点怎么说？"]
    }

    func linkRange(for quote: String) -> NSRange? {
        guard quote.first?.isWhitespace == false, quote.last?.isWhitespace == false,
              quote.contains(where: \.isLetter), let source else { return nil }
        let edge = #"[\p{L}\p{N}_]"#
        let prefix = quote.first?.isLetter == true || quote.first?.isNumber == true ? "(?<!\(edge))" : ""
        let suffix = quote.last?.isLetter == true || quote.last?.isNumber == true ? "(?!\(edge))" : ""
        let literal = NSRegularExpression.escapedPattern(for: quote)
        guard let expression = try? NSRegularExpression(pattern: prefix + literal + suffix) else { return nil }
        let matches = expression.matches(in: passage, range: NSRange(location: 0, length: passage.utf16.count))
        guard matches.count == 1, let range = matches.first?.range, NSMaxRange(range) <= source.linkableLength else { return nil }
        return range
    }
}

struct AssistantQuestionSelection: Equatable {
    let reference: AssistantQuestionReference
    private let id = UUID()
}

struct AssistantQuestionRequest {
    let question: String
    let reference: AssistantQuestionReference?
    let includeSurrounding: Bool
    let history: [AssistantQuestionTurn]
}

struct AssistantQuestionTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer = ""
    var isComplete = false
    var reference: AssistantQuestionReference?
}

@MainActor
@Observable
final class AssistantQuestionChat {
    typealias Respond = (AssistantQuestionRequest, @escaping (String) -> Void) async throws -> String

    var draft = ""
    var includeSurrounding = false
    private(set) var reference: AssistantQuestionReference?
    private(set) var turns: [AssistantQuestionTurn] = []
    private(set) var isGenerating = false
    private(set) var error: String?
    private(set) var canRetry = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: AssistantQuestionRequest?
    @ObservationIgnored private var lastSelection: AssistantQuestionSelection?
    @ObservationIgnored private var materialID: String?
    @ObservationIgnored private var conversations: [Conversation] = []

    private struct Key: Equatable {
        let material: String?
        let position: String?
        let passage: String?
    }

    private struct Conversation {
        let key: Key
        let turns: [AssistantQuestionTurn]
        let includeSurrounding: Bool
        let lastRequest: AssistantQuestionRequest?
        let error: String?
        let canRetry: Bool
    }

    var canSend: Bool { !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func selectReference(_ selection: AssistantQuestionSelection) {
        guard lastSelection != selection else { return }
        lastSelection = selection
        replaceReference(with: selection.reference)
    }

    func activate(material: String?) {
        guard materialID != material else { return }
        rememberConversation()
        materialID = material
        lastSelection = nil
        draft = ""
        restoreConversation(for: nil)
    }

    func replaceReference(with reference: AssistantQuestionReference?) {
        guard key(for: self.reference) != key(for: reference) else {
            self.reference = reference
            return
        }
        rememberConversation()
        restoreConversation(for: reference)
    }

    func startNewConversation() {
        cancelGeneration()
        conversations.removeAll { $0.key == key(for: reference) }
        includeSurrounding = false
        turns = []
        error = nil
        canRetry = false
        lastRequest = nil
    }

    func insertQuestion(_ text: String) {
        draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n" + text
    }

    private func key(for reference: AssistantQuestionReference?) -> Key {
        Key(material: reference?.source?.materialID ?? materialID,
            position: reference?.source?.positionID, passage: reference?.passage)
    }

    private func rememberConversation() {
        stop()
        guard !turns.isEmpty else { return }
        let key = key(for: reference)
        conversations.removeAll { $0.key == key }
        conversations.append(Conversation(key: key, turns: turns, includeSurrounding: includeSurrounding,
                                          lastRequest: lastRequest, error: error, canRetry: canRetry))
        if conversations.count > 64 { conversations.removeFirst() }
    }

    private func restoreConversation(for reference: AssistantQuestionReference?) {
        self.reference = reference
        let saved = conversations.last { $0.key == key(for: reference) }
        turns = saved?.turns ?? []
        includeSurrounding = saved?.includeSurrounding ?? false
        lastRequest = saved?.lastRequest
        error = saved?.error
        canRetry = saved?.canRetry ?? false
    }

    func send(using respond: @escaping Respond) {
        guard canSend else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count <= 1000 else {
            error = "问题最多输入 1000 字。"
            canRetry = false
            return
        }
        let request = AssistantQuestionRequest(question: question, reference: reference,
                                              includeSurrounding: includeSurrounding,
                                              history: Array(turns.lazy.filter(\.isComplete).suffix(3)))
        draft = ""
        turns.append(AssistantQuestionTurn(question: question, reference: reference))
        if turns.count > 12 { turns.removeFirst(turns.count - 12) }
        generate(request, using: respond)
    }

    func retry(using respond: @escaping Respond) {
        guard canRetry, let lastRequest, !isGenerating else { return }
        generate(lastRequest, using: respond)
    }

    func stop() {
        guard isGenerating else { return }
        cancelGeneration()
        error = "已停止生成。"
        canRetry = true
    }

    private func cancelGeneration() {
        task?.cancel()
        task = nil
        isGenerating = false
    }

    private func generate(_ request: AssistantQuestionRequest, using respond: @escaping Respond) {
        let index = turns.count - 1
        turns[index].answer = ""
        lastRequest = request
        error = nil
        canRetry = false
        isGenerating = true
        task = Task { [weak self] in
            do {
                let answer = try await respond(request) { [weak self] partial in
                    guard !Task.isCancelled else { return }
                    self?.turns[index].answer = partial
                }
                guard let self, !Task.isCancelled else { return }
                turns[index].answer = answer
                turns[index].isComplete = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = ReaderModel.connectionMessage(error)
                canRetry = true
            }
            if !Task.isCancelled {
                self?.isGenerating = false
                self?.task = nil
            }
        }
    }
}
