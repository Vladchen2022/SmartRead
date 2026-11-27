import Foundation
import Observation

struct AudioSubtitleSelection: Equatable {
    let cueID: UUID
    let word: TextExcerpt?
    let sentence: TextExcerpt
    let surrounding: SentenceContext?

    var phraseRequest: StudyRequest? {
        guard let word else { return nil }
        return StudyRequest(kind: .phrase, target: sentence, focusedWord: word,
                            sources: [StudySource(id: "S1", excerpt: sentence)], surrounding: surrounding)
    }

    func questionReference(in entry: AudioStudyEntry) -> AssistantQuestionReference? {
        guard let cue = entry.cues?.first(where: { $0.id == cueID }) else { return nil }
        return AssistantQuestionReference(passage: sentence.text, focus: word?.text, timestamp: audioTimeText(cue.start),
            surrounding: surrounding, source: AssistantQuestionSource(title: entry.title,
                location: .audio(entry: entry.id, cue: cueID, range: sentence.range)))
    }

    init?(entry: AudioStudyEntry, cueID: UUID, at position: Int) {
        guard let text = entry.cues?.first(where: { $0.id == cueID })?.text,
              let word = WordLookup.excerpt(at: position, in: text) else { return nil }
        self.init(entry: entry, cueID: cueID, target: SubtitleWord(text: word.text, range: word.range))
    }

    init?(entry: AudioStudyEntry, cueID: UUID, target: SubtitleWord? = nil, wholeSentence: Bool = false) {
        guard let cues = entry.cues, let index = cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        let text = cues[index].text
        let reading = ReadingIndex(text)
        guard let sentence = target.flatMap({ reading.sentence(at: $0.range.location) })
                ?? reading.articleSentences().first else { return nil }
        if let target {
            guard SubtitleWordTokenizer.isValidTarget(target, in: text),
                  let excerpt = sentence.focus(on: target) else { return nil }
            word = wholeSentence ? nil : excerpt
        } else {
            word = nil
        }
        let local = reading.context(around: sentence.range)
        let previous = local?.previousSentence ?? (index > 0 ? String(cues[index - 1].text.suffix(480)) : nil)
        let next = local?.nextSentence ?? (cues.indices.contains(index + 1) ? String(cues[index + 1].text.prefix(480)) : nil)
        self.cueID = cueID
        self.sentence = sentence
        surrounding = previous == nil && next == nil ? nil : SentenceContext(previousSentence: previous, nextSentence: next)
    }
}

extension TextExcerpt {
    func focus(on target: SubtitleWord) -> TextExcerpt? {
        guard NSIntersectionRange(range, target.range) == target.range else { return nil }
        let offset = NSRange(location: target.range.location - range.location, length: target.range.length)
        guard (text as NSString).substring(with: offset) == target.text else { return nil }
        return TextExcerpt(text: target.text, range: target.range, context: text, contextWordRange: offset)
    }
}

@MainActor
@Observable
final class AudioSubtitleAssistant {
    private(set) var selection: AudioSubtitleSelection?
    let word = AssistantLanguageLookup()
    let translation = AssistantLanguageLookup()
    let grammar = AssistantLanguageLookup()
    private(set) var grammarExpanded = false
    private(set) var phrase: AssistantLookupResult = .idle
    @ObservationIgnored private var phraseTask: Task<Void, Never>?

    func clear() {
        phraseTask?.cancel()
        phraseTask = nil
        word.clear()
        translation.clear()
        grammar.clear()
        grammarExpanded = false
        phrase = .idle
        selection = nil
    }

    func select(_ target: AudioSubtitleSelection, using reader: ReaderModel) {
        clear()
        selection = target
        if let excerpt = target.word {
            word.load(.init(kind: .word, excerpt: excerpt, surrounding: target.surrounding), using: reader)
        }
        translate(using: reader)
    }

    func translate(using reader: ReaderModel) {
        guard let selection else { return }
        translation.load(.init(kind: .translation, excerpt: selection.sentence, surrounding: selection.surrounding), using: reader)
    }

    func retryWord(using reader: ReaderModel) {
        guard let selection, let excerpt = selection.word else { return }
        word.load(.init(kind: .word, excerpt: excerpt, surrounding: selection.surrounding), using: reader)
    }

    func toggleGrammar(using reader: ReaderModel) {
        grammarExpanded.toggle()
        if grammarExpanded, case .idle = grammar.result { analyze(using: reader) }
    }

    func analyze(using reader: ReaderModel) {
        guard let selection else { return }
        grammar.load(.init(kind: .analysis, excerpt: selection.sentence, includeTranslation: false,
                           surrounding: selection.surrounding), using: reader)
    }

    func showPhrase(using reader: ReaderModel) {
        guard let request = selection?.phraseRequest else { return }
        phraseTask?.cancel()
        phrase = .loading("")
        phraseTask = Task { [weak self] in
            do {
                let study = try await reader.fetchLanguageStudy(request)
                try Task.checkCancellation()
                self?.phrase = .phrase(study)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phrase = .failed(ReaderModel.connectionMessage(error))
            }
        }
    }

    func hidePhrase() {
        phraseTask?.cancel()
        phraseTask = nil
        phrase = .idle
    }
}
