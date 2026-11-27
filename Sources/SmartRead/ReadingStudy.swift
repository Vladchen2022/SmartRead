import Foundation
import NaturalLanguage

enum StudyKind: String, CaseIterable {
    case structure, reference, phrase, simpler, paragraph, hints, background, check

    var label: String {
        switch self {
        case .structure: "先看主干"
        case .reference: "指代与省略"
        case .phrase: "看完整搭配"
        case .simpler: "简单英文"
        case .paragraph: "这段在说什么"
        case .hints: "本段助读提示"
        case .background: "读前背景"
        case .check: "检查理解"
        }
    }

    var symbol: String {
        switch self {
        case .structure: "text.alignleft"
        case .reference: "arrow.turn.up.left"
        case .phrase: "link"
        case .simpler: "text.word.spacing"
        case .paragraph: "text.justify.left"
        case .hints: "lightbulb"
        case .background: "book"
        case .check: "questionmark.bubble"
        }
    }

    var instructions: String {
        switch self {
        case .structure:
            """
            overview 用一句中文说主句在讲什么。只分析 target 这句，在 items 中逐字引用它的主语 subject、主语对应的动词或谓语短语 predicate，以及帮助理解的从句 clause 或修饰成分 modifier。优先语义完整的短片段，最多 6 项。各项的 quote 不重叠。存在嵌套时，只标解释所需的最外层，或选不重叠的关键部分。text 简短说明作用。冒号前的标题或名词短语可标为补充说明，冒号后直接提出的问句应按独立问句理解。遇到省略或不完整结构，可只标能确认的成分。主句主语和主句谓语优先。
            """
        case .reference:
            """
            在 target 这句找指代或省略。优先解释 focus，否则解释一个影响理解的指代或被省略的成分。找到指向时，items 必须成对写：先用 referring 引用代词或省略发生处的字词，再用 referent 从相应的 source 逐字引用被指向的实体或事件。不能只在 overview 或 text 里讲先行词，App 需要 referent 项才能跳到前文。指向整件事时可引用那句完整原文。找不到明确先行词时解释原因，给最多两个有原文依据的可能。省略的内容只写进 text，不写进 quote。overview 简述关系。
            """
        case .phrase:
            """
            只解释包含 focus 的连续英语搭配、短语或惯用法，quote 为完整搭配的原文连续字词，role 为 phrase，text 用简体中文解释本句含义。最多一项。没有明确搭配则 items 为空，overview 简短说明。
            """
        case .simpler:
            """
            对 sources 每个句子各生成一个 item，按同一顺序保留 source。role 写 rewrite，quote 为空，text 用简单英文改写该句，可拆成更短的句子。保留所有数字（保留原数字写法）、人名、否定、条件、因果、说话者和不确定语气。不要把概括、推断或背景加进去。overview 为空。
            """
        case .paragraph:
            """
            overview 用一句中文交代 target 这一段的中心意思，再用极短一句说明在交代背景、举证、比较、提出主张或做预测中的哪一件事。保持原文的条件和语气。items 给 1–2 条能支持段意的简短原文引句，role 为 evidence，text 说明这句支持哪一点。
            """
        case .hints:
            """
            找出 target 这一段中最可能卡住理解的 0–3 处。优先难搭配、术语或连接词，跳过普通词。每个引用必须短而精确，role 为 hint，text 用一句中文解除卡点。不需要时返回空数组。overview 可以为空。
            """
        case .background:
            """
            为读懂 target 这一段解释最多三个必要的专业词、缩写或背景概念，role 为 background，quote 为对应原文术语，text 用一两句中文解释普通知识和它在这段中的用途。没有必要的术语时简述即可。不得添加未经原文支持的时事、数据或作者立场。
            """
        case .check:
            """
            只根据 target 出一道简短中文理解题，问原文的因果、条件、对比，或它的中心意思。填入 question。answer 写可自行核对的简洁答案。items 给一两条能定位的原文证据，role 为 evidence。overview 为空。题目无需依赖文章之外的知识。
            """
        }
    }

    var tokenBudget: Int { self == .simpler ? 3_600 : 1_250 }
}

enum MarkStyle: String, Hashable {
    case subject, predicate, clause, modifier, referring, referent, phrase, hint, evidence, background, word, spoken, listening

    var label: String {
        switch self {
        case .subject: "主语"
        case .predicate: "主句谓语"
        case .clause: "从句"
        case .modifier: "补充说明"
        case .referring: "指代表达"
        case .referent: "指向的内容"
        case .phrase: "搭配"
        case .hint: "助读提示"
        case .evidence: "原文依据"
        case .background: "背景术语"
        case .word: "查词"
        case .spoken: "当前朗读句"
        case .listening: "听力标记"
        }
    }
}

struct ReaderMark: Hashable {
    let range: NSRange
    let style: MarkStyle
}

struct ReadingJump: Equatable {
    let id = UUID()
    let range: NSRange
    var select = false
    var showInline = false
    var alignToTop = false
}

struct StudySource: Hashable, Encodable {
    let id: String
    let excerpt: TextExcerpt

    private enum CodingKeys: String, CodingKey { case id, text }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(excerpt.text, forKey: .text)
    }
}

struct StudyRequest: Hashable {
    let kind: StudyKind
    let target: TextExcerpt
    let focusedWord: TextExcerpt?
    let sources: [StudySource]
    var compactStructure = false
    var surrounding: SentenceContext?

    var instructions: String {
        guard compactStructure else { return kind.instructions }
        return """
        只讲 target 这一句。参考 surrounding 给出的前后句判断词义和动作对象。overview 用一句简短中文概括谁做了什么；有并列动作时在这里说全。items 最多三项，source 均写 S1。先逐字引用主语 subject 和主句谓语 predicate；谓语 quote 只写连续的动词或短动词词组，别带上宾语。再选一处最影响理解的从句 clause、搭配 phrase、指代 referring 或修饰 modifier。text 每项只写一句简短中文说明。引用来自原文且不重叠。省略成分用中文解释，不能捏造原文。
        """
    }

    func input() throws -> String {
        struct Input: Encodable {
            let target: String
            let focus: String?
            let markedSentence: String?
            let sources: [StudySource]
            let surrounding: SentenceContext?
        }
        let marked = focusedWord.flatMap { focus -> String? in
            guard NSIntersectionRange(target.range, focus.range) == focus.range else { return nil }
            let range = NSRange(location: focus.range.location - target.range.location, length: focus.range.length)
            return (target.text as NSString).replacingCharacters(in: range, with: "⟦\(focus.text)⟧")
        }
        let input = Input(target: target.text, focus: focusedWord?.text, markedSentence: marked, sources: sources,
                          surrounding: surrounding)
        return String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    }
}

struct ReadingIndex {
    let text: String
    private let paragraphs: [TextExcerpt]

    init(_ text: String) {
        self.text = text
        let ns = text as NSString
        var paragraphs: [TextExcerpt] = []
        var position = 0
        while position < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: position, length: 0))
            if let excerpt = Self.excerpt(within: range, in: ns) { paragraphs.append(excerpt) }
            position = NSMaxRange(range)
        }
        self.paragraphs = paragraphs
    }

    func excerpt(in range: NSRange) -> TextExcerpt? {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= text.utf16.count else { return nil }
        return Self.excerpt(within: range, in: text as NSString)
    }

    func paragraph(at position: Int) -> TextExcerpt? {
        paragraphIndex(at: position).map { paragraphs[$0] }
    }

    func sentence(at position: Int) -> TextExcerpt? {
        guard let paragraph = paragraph(at: position) else { return nil }
        let sentences = sentences(in: paragraph)
        return sentences.first { NSMaxRange($0.range) > position } ?? sentences.last
    }

    func articleSentences() -> [TextExcerpt] {
        paragraphs.flatMap { sentences(in: $0) }
    }

    func context(around range: NSRange) -> SentenceContext? {
        guard range.length > 0, let first = paragraphIndex(at: range.location),
              let last = paragraphIndex(at: NSMaxRange(range) - 1) else { return nil }
        let previous = sentences(in: paragraphs[first]).last { NSMaxRange($0.range) <= range.location }
            ?? (first > 0 ? sentences(in: paragraphs[first - 1]).last : nil)
        let next = sentences(in: paragraphs[last]).first { $0.range.location >= NSMaxRange(range) }
            ?? (last + 1 < paragraphs.count ? sentences(in: paragraphs[last + 1]).first : nil)
        guard previous != nil || next != nil else { return nil }
        return SentenceContext(previousSentence: previous.map { String($0.text.suffix(480)) },
                               nextSentence: next.map { String($0.text.prefix(480)) })
    }

    func favoriteContext(for range: NSRange) -> (paragraph: Int, sentence: String)? {
        guard let paragraph = paragraphIndex(at: range.location) else { return nil }
        let first = sentence(at: range.location)?.range ?? range
        let last = sentence(at: NSMaxRange(range) - 1)?.range ?? range
        let span = NSUnionRange(range, NSUnionRange(first, last))
        guard let context = excerpt(in: span) else { return nil }
        return (paragraph + 1, context.text)
    }

    func sentences(in excerpt: TextExcerpt) -> [TextExcerpt] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = excerpt.text
        tokenizer.setLanguage(.english)
        let ns = text as NSString
        let ranges = tokenizer.tokens(for: excerpt.text.startIndex..<excerpt.text.endIndex)
        let results = ranges.compactMap { range in
            let local = NSRange(range, in: excerpt.text)
            return Self.excerpt(within: NSRange(location: excerpt.range.location + local.location, length: local.length), in: ns)
        }
        return results.isEmpty ? [excerpt] : results
    }

    func request(_ kind: StudyKind, at position: Int, selection: TextExcerpt? = nil,
                 word: TextExcerpt? = nil) throws -> StudyRequest {
        guard let index = paragraphIndex(at: position) else { throw ReaderError.message("没有可分析的正文。") }
        let paragraph = paragraphs[index]
        let target: TextExcerpt
        let passages: [TextExcerpt]
        let focus: TextExcerpt?

        switch kind {
        case .structure, .phrase, .reference:
            target = sentence(at: position) ?? paragraph
            focus = kind == .structure ? nil : word
            if kind == .reference {
                let previous = paragraphs[max(0, index - 2)..<index]
                passages = previous.map { tail($0, limit: 1_000) } + [paragraph.range.length <= 2_400 ? paragraph : target]
            } else {
                passages = [target]
            }
        case .simpler:
            target = paragraph
            passages = sentences(in: paragraph)
            focus = nil
        case .check:
            target = selection.flatMap { excerpt(in: $0.range) } ?? paragraph
            passages = [target]
            focus = nil
        case .paragraph, .hints, .background:
            target = paragraph
            passages = [target]
            focus = nil
        }

        guard target.range.length <= (kind == .simpler ? 2_200 : 4_500), passages.count <= 18 else {
            throw ReaderError.message(kind == .simpler ? "这段太长。可先把原文分成较短的段落，再试简单英文。"
                                                       : "这段太长。请选一小段正文后用翻译或语法解析。")
        }
        let sources = passages.enumerated().map { StudySource(id: "S\($0.offset + 1)", excerpt: $0.element) }
        return StudyRequest(kind: kind, target: target, focusedWord: focus, sources: sources)
    }

    private func tail(_ excerpt: TextExcerpt, limit: Int) -> TextExcerpt {
        guard excerpt.range.length > limit else { return excerpt }
        let sentences = sentences(in: excerpt)
        if let start = sentences.first(where: { NSMaxRange(excerpt.range) - $0.range.location <= limit }) {
            let tail = NSRange(location: start.range.location, length: NSMaxRange(excerpt.range) - start.range.location)
            return Self.excerpt(within: tail, in: text as NSString) ?? start
        }
        let end = NSMaxRange(excerpt.range)
        let body = text as NSString
        let range = body.rangeOfComposedCharacterSequences(for: NSRange(location: end - limit, length: limit))
        return Self.excerpt(within: range, in: body) ?? excerpt
    }

    private func paragraphIndex(at position: Int) -> Int? {
        guard !paragraphs.isEmpty else { return nil }
        var low = 0
        var high = paragraphs.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(paragraphs[mid].range) <= position { low = mid + 1 }
            else { high = mid }
        }
        return min(low, paragraphs.count - 1)
    }

    private static func excerpt(within range: NSRange, in text: NSString) -> TextExcerpt? {
        let visible = CharacterSet.whitespacesAndNewlines.inverted
        let first = text.rangeOfCharacter(from: visible, range: range).location
        guard first != NSNotFound else { return nil }
        let last = text.rangeOfCharacter(from: visible, options: .backwards, range: range)
        let trimmed = NSRange(location: first, length: NSMaxRange(last) - first)
        return TextExcerpt(text: text.substring(with: trimmed), range: trimmed, context: "")
    }
}

struct StudyResult {
    struct Item: Identifiable {
        let id: Int
        let style: MarkStyle?
        let quote: String
        let detail: String
        let range: NSRange
    }

    let overview: String
    let items: [Item]
    let question: String
    let answer: String
    let note: String?

    var marks: [ReaderMark] {
        items.compactMap { item in item.style.map { ReaderMark(range: item.range, style: $0) } }
    }
}

struct StudyReply: Decodable {
    struct Item: Decodable {
        let role: String
        let source: String
        let quote: String
        let text: String
        let occurrence: Int?
    }

    let overview: String
    let items: [Item]
    let question: String
    let answer: String

    func validated(for request: StudyRequest) throws -> StudyResult {
        let sources = Dictionary(uniqueKeysWithValues: request.sources.map { ($0.id, $0.excerpt) })
        var accepted: [StudyResult.Item] = []
        for (index, item) in items.enumerated() {
            guard let source = sources[item.source] else { continue }
            let detail = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if request.kind == .simpler {
                guard item.role == "rewrite", !detail.isEmpty, Self.numbers(in: source.text) == Self.numbers(in: detail),
                      !accepted.contains(where: { $0.range == source.range }) else { continue }
                accepted.append(.init(id: index, style: nil, quote: source.text, detail: detail, range: source.range))
                continue
            }

            guard let style = MarkStyle(rawValue: item.role) else { continue }
            if request.compactStructure {
                guard [.subject, .predicate, .clause, .modifier, .phrase, .referring].contains(style) else { continue }
            } else {
                guard allowed(style, for: request.kind) else { continue }
            }
            let mustContainWord = request.kind == .phrase || style == .referring
            let focus = mustContainWord ? request.focusedWord?.range : nil
            guard let match = Self.find(item.quote, in: source, containing: focus, occurrence: item.occurrence),
                  !accepted.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
            if request.kind == .phrase {
                let words = WordLookup.pattern.numberOfMatches(in: match.text, range: NSRange(match.text.startIndex..., in: match.text))
                guard words > 1 else { continue }
            }
            if request.kind == .structure, style == .predicate, match.text.hasSuffix("?") { continue }
            if [.structure, .phrase, .hints, .background, .paragraph, .check].contains(request.kind)
                || style == .referring {
                guard NSIntersectionRange(request.target.range, match.range) == match.range else { continue }
            }
            accepted.append(.init(id: index, style: style, quote: match.text, detail: detail, range: match.range))
        }
        if request.kind == .reference, !accepted.contains(where: { $0.style == .referring }) {
            accepted.removeAll()
        }
        if request.compactStructure {
            let subject = accepted.first { $0.style == .subject }
            let predicate = accepted.first { $0.style == .predicate }
            let difficulty = accepted.first { $0.style != .subject && $0.style != .predicate }
            accepted = [subject, predicate, difficulty].compactMap { $0 }
        } else if [.structure, .simpler].contains(request.kind) {
            accepted.sort { $0.range.location < $1.range.location }
        }
        if request.kind == .hints { accepted = Array(accepted.prefix(3)) }
        if request.kind == .phrase { accepted = Array(accepted.prefix(1)) }
        if request.kind == .check {
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !accepted.isEmpty else {
                throw ReaderError.message("这次没生成有原文依据的理解题，请重试。")
            }
        }
        if request.kind == .simpler, accepted.isEmpty {
            throw ReaderError.message("改写没有通过原句和数字核对，请重试。")
        }
        let summary = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String?
        if request.kind == .simpler, accepted.count != request.sources.count {
            note = "部分句子未通过核对，下面只显示能与原文对照的改写。"
        } else if accepted.isEmpty && [.structure, .paragraph, .reference].contains(request.kind) {
            note = "这次未找到能明确定位的原文片段。"
        } else {
            note = nil
        }
        return StudyResult(overview: summary, items: accepted, question: question, answer: answer, note: note)
    }

    static func find(_ quote: String, in source: TextExcerpt, containing focus: NSRange? = nil,
                     occurrence: Int? = nil) -> TextExcerpt? {
        let term = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let text = source.text as NSString
        var matches: [NSRange] = []
        var position = 0
        while position < text.length {
            let search = NSRange(location: position, length: text.length - position)
            let range = text.range(of: term, options: .literal, range: search)
            guard range.location != NSNotFound else { break }
            position = NSMaxRange(range)
            guard let candidate = Range(range, in: source.text), isWholeTextSpan(candidate, in: source.text) else { continue }
            matches.append(range)
        }
        let match: NSRange?
        if let focus {
            match = matches.first {
                let global = NSRange(location: source.range.location + $0.location, length: $0.length)
                return NSIntersectionRange(focus, global) == focus
            }
        } else if let occurrence, occurrence > 0, occurrence <= matches.count {
            match = matches[occurrence - 1]
        } else {
            match = matches.count == 1 && occurrence == nil ? matches.first : nil
        }
        guard let match else { return nil }
        return TextExcerpt(text: text.substring(with: match),
                          range: NSRange(location: source.range.location + match.location, length: match.length), context: "")
    }

    private static func isWholeTextSpan(_ range: Range<String.Index>, in text: String) -> Bool {
        func word(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "'" || character == "’"
        }
        if range.lowerBound != text.startIndex, word(text[range.lowerBound]),
           word(text[text.index(before: range.lowerBound)]) { return false }
        if range.upperBound != text.endIndex, word(text[text.index(before: range.upperBound)]),
           word(text[range.upperBound]) { return false }
        return true
    }

    private func allowed(_ style: MarkStyle, for kind: StudyKind) -> Bool {
        switch kind {
        case .structure: [.subject, .predicate, .clause, .modifier].contains(style)
        case .reference: [.referring, .referent].contains(style)
        case .phrase: style == .phrase
        case .paragraph, .check: style == .evidence
        case .hints: style == .hint
        case .background: style == .background
        case .simpler: false
        }
    }

    private static let numberPattern = try! NSRegularExpression(pattern: #"[-−+]?\$?\d[\d,.]*\d%?|[-−+]?\$?\d%?"#)

    private static func numbers(in text: String) -> [String] {
        numberPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { (text as NSString).substring(with: $0.range) }
    }
}
