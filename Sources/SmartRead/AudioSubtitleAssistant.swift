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

    init?(entry: AudioStudyEntry, cueID: UUID, target: SubtitleWord? = nil) {
        guard let cues = entry.cues, let index = cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        let text = cues[index].text
        let reading = ReadingIndex(text)
        guard let sentence = target.flatMap({ reading.sentence(at: $0.range.location) })
                ?? reading.articleSentences().first else { return nil }
        if let target {
            guard SubtitleWordTokenizer.isValidTarget(target, in: text),
                  let excerpt = sentence.focus(on: target) else { return nil }
            word = excerpt
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
    private(set) var action: AssistantAction?
    private(set) var result: AssistantLookupResult = .loading("")
    @ObservationIgnored private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        selection = nil
        action = nil
        result = .loading("")
    }

    func show(_ action: AssistantAction, for selection: AudioSubtitleSelection, using reader: ReaderModel) {
        guard action == .sentence || selection.word != nil else { return }
        task?.cancel()
        self.selection = selection
        self.action = action
        result = .loading("")
        task = Task { [weak self] in
            do {
                let answer: AssistantLookupResult
                if action == .phrase, let request = selection.phraseRequest {
                    answer = .phrase(try await reader.fetchLanguageStudy(request))
                } else {
                    let request = LookupRequest(kind: action == .word ? .word : .analysis,
                                                excerpt: action == .word ? selection.word ?? selection.sentence : selection.sentence,
                                                surrounding: selection.surrounding)
                    let text = try await reader.fetchLanguageAnswer(request) { partial in
                        guard !Task.isCancelled else { return }
                        self?.result = .loading(partial)
                    }
                    answer = .answer(text)
                }
                guard !Task.isCancelled else { return }
                self?.result = answer
            } catch {
                guard !Task.isCancelled else { return }
                self?.result = .failed(ReaderModel.connectionMessage(error))
            }
        }
    }
}
