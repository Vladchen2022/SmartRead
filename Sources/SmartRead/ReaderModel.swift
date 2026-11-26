import Foundation
import CoreGraphics
import Observation

@MainActor
@Observable
final class ReaderModel {
    enum Connection {
        case checking, connected, unavailable(String)
    }

    var article: Article { library.current ?? .sample }
    var history: [ArticleHistoryEntry] { library.history }
    var articleVersion = UUID()
    var selection: TextExcerpt?
    private(set) var questionSelection: AssistantQuestionSelection?
    private var lastAssistantWord: TextExcerpt?
    var lookup: LookupRequest?
    var answer = ""
    var lookupError: String?
    var isLookingUp = false
    var notice: String?
    private(set) var lookupFinished = false
    private(set) var learningRecord: LearningRecord?
    private var bookLearningRecords: [LearningRecord] = []
    private(set) var isLoadingLearningRecord = false
    private(set) var shownFavorite: LearningFavorite?
    private(set) var translationAnalysis: TranslationAnalysis?
    private(set) var study: ActiveStudy?
    private(set) var jump: ReadingJump?
    private(set) var inlineTranslation: InlineTranslation?
    private(set) var assistedReading = false
    private(set) var hints: StudyResult?
    private(set) var hintStatus: String?

    private var library: ArticleLibrary
    private var index: ReadingIndex
    private var readingPosition = 0
    private var savedPositions: [String: SavedReadingPosition] = [:]
    private var positionKey = ""
    private var rememberedSentence: NSRange?
    private var hintScope: NSRange?
    private var hintTask: Task<Void, Never>?
    private var studyTask: Task<Void, Never>?
    private var studyCache: [StudyCacheKey: StudyResult] = [:]
    private(set) var endpoint: String
    var preferredModel: String {
        didSet {
            defaults.set(preferredModel, forKey: "lmStudioModel")
            if oldValue != preferredModel, assistedReading { resetHints(); refreshHints() }
        }
    }
    private(set) var models: [String] = []
    private(set) var connection: Connection = .checking
    private(set) var isImporting = false
    private(set) var isLoadingPDF = false
    let weeklyFavorites: WeeklyFavoriteSync
    let questionFavorites: AssistantQuestionFavorites
    private let questionChats: [ReaderMode: AssistantQuestionChat] = [
        .text: AssistantQuestionChat(), .audio: AssistantQuestionChat(), .video: AssistantQuestionChat()
    ]

    var questionMaterialID: String { positionKey }

    func questionChat(for mode: ReaderMode) -> AssistantQuestionChat { questionChats[mode]! }

    private let defaults: UserDefaults
    private let store: ArticleStore
    private let pdfBooks: PDFBookStore
    private(set) var recoveryNeeded: Set<ArticleStore.RecordFile> = []
    private var cachedBookID: String?
    private let learningStore: LearningRecordStore
    private let importedLearning: ImportedLearningRecords
    private let backgroundLearningRecords: BackgroundLearningRecords?
    private let backgroundLegacyRecords: BackgroundLearningRecords
    @ObservationIgnored private var learningRecordTask: Task<Void, Never>?
    @ObservationIgnored private var checkedLegacyRecords: Set<String> = []
    private let importer = ArticleImporter()
    private var lookupTask: Task<Void, Never>?
    private var translationAnalysisTask: Task<Void, Never>?
    private var translationSummaryTask: Task<Void, Never>?
    private var generation: UUID?
    private var checkGeneration: UUID?
    private var cache: [CacheKey: String] = [:]

    init(defaults: UserDefaults = .standard, store: ArticleStore = ArticleStore(),
         learningStore: LearningRecordStore = LearningRecordStore(), loadsLearningRecordsInBackground: Bool = false) {
        self.defaults = defaults
        self.store = store
        self.questionFavorites = AssistantQuestionFavorites(file: store.questionFavoritesFile)
        self.pdfBooks = PDFBookStore(root: store.pdfBooksDirectory)
        self.learningStore = learningStore
        self.importedLearning = ImportedLearningRecords(root: store.importedLearningDirectory)
        self.weeklyFavorites = WeeklyFavoriteSync(defaults: defaults, queueFile: store.weeklyFavoriteQueueFile)
        self.backgroundLegacyRecords = BackgroundLearningRecords(store: learningStore)
        self.backgroundLearningRecords = loadsLearningRecordsInBackground ? BackgroundLearningRecords(store: learningStore) : nil
        endpoint = defaults.string(forKey: "lmStudioEndpoint") ?? LMStudioClient.defaultEndpoint
        preferredModel = defaults.string(forKey: "lmStudioModel") ?? ""
        let loaded: ArticleLibrary
        let libraryFailed: Bool
        do {
            loaded = try store.load()
            libraryFailed = false
        } catch {
            loaded = ArticleLibrary()
            libraryFailed = true
        }
        library = loaded
        index = ReadingIndex((loaded.current ?? .sample).body)
        if libraryFailed { recoveryNeeded.insert(.library) }
        loadLearningRecord()
        do { savedPositions = try store.loadPositions() }
        catch { recoveryNeeded.insert(.positions) }
        if !recoveryNeeded.isEmpty { notice = "读取资料失败。请打开「历史记录」恢复，原文件已保留。" }
        restoreReadingPosition()
    }

    func recover(_ kind: ArticleStore.RecordFile) throws {
        try store.recover(kind)
        switch kind {
        case .library:
            library = try store.load()
            // Refresh the reading session without archiving or saving an item.
            display(library.current ?? .sample, refreshLearningSource: false)
        case .positions:
            savedPositions = try store.loadPositions()
            restoreReadingPosition()
        }
        recoveryNeeded.remove(kind)
    }

    func backfillWeeklyFavorites() {
        var articleURLs: [URL: URL] = [:]
        for source in [library.current].compactMap({ $0 }) + history.map(\.article) {
            if source.learningSource == nil, let url = source.sourceURL {
                articleURLs[importedLearning.file(for: source)] = url
            }
        }
        weeklyFavorites.backfill(records: importedLearning, articleURLs: articleURLs)
    }

    func connect(to address: String? = nil) async {
        let id = UUID()
        checkGeneration = id
        connection = .checking

        do {
            let client = try LMStudioClient(endpoint: address ?? endpoint)
            let available = try await client.models()
            guard checkGeneration == id, !Task.isCancelled else { return }
            if client.baseURL.absoluteString != endpoint {
                endpoint = client.baseURL.absoluteString
                defaults.set(endpoint, forKey: "lmStudioEndpoint")
            }
            models = available
            connection = .connected
            if assistedReading { resetHints(); refreshHints() }
        } catch {
            guard checkGeneration == id, !Task.isCancelled else { return }
            models = []
            connection = .unavailable(Self.connectionMessage(error))
        }
    }

    func importText(_ text: String, title: String) throws {
        try adopt(Article.pasted(text, title: title))
    }

    func importFile(_ url: URL) throws {
        let imported = try importer.textFile(url, relativePath: learningStore.sourcePath(for: url))
        try adopt(imported, refreshLearningSource: true)
    }

    func importPDFBook(_ url: URL) async throws {
        guard !isLoadingPDF else { return }
        let version = articleVersion
        isLoadingPDF = true
        defer { isLoadingPDF = false }
        let book = try await pdfBooks.importBook(url)
        try Task.checkCancellation()
        guard version == articleVersion else { throw CancellationError() }
        if let existing = ([library.current].compactMap { $0 } + history.map(\.article))
            .first(where: { $0.pdfPage?.book.id == book.id }) {
            try adopt(existing)
            return
        }
        guard let page = try await pdfBooks.article(for: book, at: 0, englishOnly: false) else { return }
        try Task.checkCancellation()
        guard version == articleVersion else { throw CancellationError() }
        try adopt(page)
    }

    func turnPDFPage(_ direction: Int) async {
        guard direction == -1 || direction == 1, let page = article.pdfPage, page.chapter == nil else { return }
        await loadPDFPage(page, at: page.index + direction, step: direction, englishOnly: page.englishOnly)
    }

    func jumpToPDFPage(_ pageNumber: Int) async {
        guard let page = article.pdfPage else { return }
        guard (1...page.book.pageCount).contains(pageNumber) else {
            notice = "请输入 1–\(page.book.pageCount) 范围内的 PDF 页码。"
            return
        }
        await loadPDFPage(page, at: pageNumber - 1, englishOnly: page.englishOnly)
    }

    func setPDFEnglishOnly(_ enabled: Bool) async {
        guard let page = article.pdfPage, page.chapter == nil else { return }
        await loadPDFPage(page, at: page.index, englishOnly: enabled)
    }

    func pdfPagePreview(_ location: PDFBookLocation, at index: Int? = nil) async throws -> CGImage {
        try await pdfBooks.preview(location, at: index)
    }

    func pdfBoxes(_ book: PDFBook, at index: Int) async throws -> [CGRect] {
        try await pdfBooks.savedBoxes(for: book, at: index)
    }

    func correctPDF(_ location: PDFBookLocation, at index: Int, boxes: [CGRect]) async throws {
        guard !isLoadingPDF, article.pdfPage == location else { throw CancellationError() }
        isLoadingPDF = true
        defer { isLoadingPDF = false }
        let version = articleVersion
        let next = try await pdfBooks.correct(location, at: index, boxes: boxes)
        try Task.checkCancellation()
        guard version == articleVersion else { throw CancellationError() }
        try adopt(next)
    }

    var currentPDFSourcePage: Int? {
        article.pdfPage?.sourcePage(at: selection?.range.location ?? readingPosition)
    }

    func pdfProgress(for item: Article, current: Bool = false) -> String? {
        guard let page = item.pdfPage else { return nil }
        guard let reading = page.chapter else { return page.pageLabel }
        let saved = savedPositions[SavedReadingPosition.key(for: item)]
        let position = current ? readingPosition : saved?.chapterOffset ?? saved?.sentenceStart ?? 0
        return "\(reading.chapter.label) · PDF 第 \(page.sourcePage(at: position) + 1) 页"
    }

    func pdfChapterChoices(for book: PDFBook) async throws -> [PDFChapter] {
        try await pdfBooks.chapters(for: book)
    }

    func startPDFChapterReading() async -> Bool {
        guard let page = article.pdfPage, page.chapter == nil, !isLoadingPDF else { return true }
        let version = articleVersion
        isLoadingPDF = true
        defer { isLoadingPDF = false }
        do {
            let chapters = try await pdfBooks.chapters(for: page.book)
            guard version == articleVersion, !Task.isCancelled else { return true }
            guard let target = chapters.last(where: { $0.firstPage <= page.index }) ?? chapters.first else { return false }
            let next = try await pdfBooks.chapterArticle(for: page.book, chapter: target, englishOnly: page.englishOnly)
            guard version == articleVersion, !Task.isCancelled else { return true }
            try adoptChapter(next, from: page, keepPagePosition: true)
        } catch {
            if version == articleVersion, !Task.isCancelled { notice = error.localizedDescription }
        }
        return true
    }

    func loadPDFChapter(_ chapter: PDFChapter, join: PDFChapterJoin = .automatic) async throws {
        guard let page = article.pdfPage, !isLoadingPDF else { throw CancellationError() }
        let version = articleVersion
        isLoadingPDF = true
        defer { isLoadingPDF = false }
        let next = try await pdfBooks.chapterArticle(for: page.book, chapter: chapter, englishOnly: page.englishOnly, join: join)
        try Task.checkCancellation()
        guard version == articleVersion else { throw CancellationError() }
        try adoptChapter(next, from: page, keepPagePosition: false)
    }

    func openPDFPageView() async {
        guard let page = article.pdfPage, let source = currentPDFSourcePage else { return }
        await loadPDFPage(page, at: source, englishOnly: page.englishOnly)
    }

    private func adoptChapter(_ next: Article, from page: PDFBookLocation, keepPagePosition: Bool) throws {
        let sentence = index.sentence(at: readingPosition)?.text
        try adopt(next)
        guard keepPagePosition, let reading = next.pdfPage?.chapter,
              savedPositions[positionKey] == nil,
              let anchorIndex = reading.anchors.firstIndex(where: { $0.page == page.index }) else { return }
        let start = reading.anchors[anchorIndex].offset
        let end = reading.anchors.dropFirst(anchorIndex + 1).first?.offset ?? next.body.utf16.count
        let matched = sentence.flatMap { text -> Int? in
            let match = (next.body as NSString).range(of: text, options: [], range: NSRange(location: start, length: end - start))
            return match.location == NSNotFound ? nil : match.location
        }
        let position = matched ?? start
        if let target = index.sentence(at: position) {
            readingPosition = max(target.range.location, start)
            jump = ReadingJump(range: NSRange(location: readingPosition, length: 0), alignToTop: true)
            rememberReadingPosition(at: readingPosition)
        }
    }

    private func loadPDFPage(_ page: PDFBookLocation, at index: Int, step: Int = 0, englishOnly: Bool) async {
        guard !isLoadingPDF, (0..<page.book.pageCount).contains(index),
              index != page.index || englishOnly != page.englishOnly || page.chapter != nil else { return }
        let version = articleVersion
        isLoadingPDF = true
        defer { isLoadingPDF = false }
        do {
            let next = try await pdfBooks.article(for: page.book, at: index, step: step, englishOnly: englishOnly)
            guard !Task.isCancelled, version == articleVersion else { return }
            guard let next else {
                notice = step > 0 ? "后面没有可读的英文页。" : "前面没有可读的英文页。"
                return
            }
            try adopt(next)
        } catch {
            if !Task.isCancelled, version == articleVersion { notice = error.localizedDescription }
        }
    }

    func openHistoryArticle(_ id: UUID) throws {
        guard let entry = history.first(where: { $0.id == id }) else { return }
        try adopt(entry.article)
    }

    var previousReadingEntry: ArticleHistoryEntry? {
        history.first {
            let position = savedPositions[SavedReadingPosition.key(for: $0.article)]
            return position?.completed == false || ($0.article.pdfPage != nil && position == nil)
        }
    }

    func deleteHistoryArticle(_ id: UUID) throws {
        var next = library
        next.history.removeAll { $0.id == id }
        try saveLibrary(next)
    }

    func clearHistory() throws {
        var next = library
        next.history.removeAll()
        try saveLibrary(next)
    }

    func importLink(_ address: String) async throws {
        isImporting = true
        defer { isImporting = false }
        do {
            let imported = try await importer.webpage(address)
            try Task.checkCancellation()
            try adopt(imported)
        } catch let error as URLError where error.code != .cancelled {
            throw ReaderError.message("网页请求失败。请在浏览器打开原文后，复制正文导入。")
        }
    }

    var focusedWord: TextExcerpt? {
        guard selection == nil, lookup?.kind == .word else { return nil }
        return lookup?.excerpt
    }

    var marks: [ReaderMark] {
        var result = hints?.marks ?? []
        if let study {
            if study.kind != .check || study.answerRevealed { result += study.result?.marks ?? [] }
            if study.kind == .simpler, let jump,
               study.result?.items.contains(where: { $0.range == jump.range }) == true {
                result.append(ReaderMark(range: jump.range, style: .evidence))
            }
        } else if let focusedWord {
            let phrase = wordPhrase
            result.append(ReaderMark(range: phrase?.range ?? focusedWord.range, style: phrase == nil ? .word : .phrase))
        }
        if study == nil, let analysis = translationAnalysis, analysis.isExpanded,
           selection.map({ NSIntersectionRange($0.range, analysis.excerpt.range).length > 0 }) ?? true {
            result += analysis.summary?.marks ?? []
        }
        return result
    }

    private var wordPhrase: TextExcerpt? {
        guard let lookup, lookup.kind == .word, let relativeWord = lookup.excerpt.contextWordRange,
              let line = answer.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("搭配：") }),
              let delimiter = line.firstIndex(of: "｜") else { return nil }
        let context = lookup.excerpt.context
        let range = NSRange(location: lookup.excerpt.range.location - relativeWord.location, length: context.utf16.count)
        let source = TextExcerpt(text: context, range: range, context: "")
        let quote = String(line[line.index(line.startIndex, offsetBy: 3)..<delimiter]).trimmingCharacters(in: .whitespaces)
        guard let match = StudyReply.find(quote, in: source, containing: lookup.excerpt.range),
              match.range != lookup.excerpt.range else { return nil }
        return match
    }

    var lookupFavorite: LearningFavorite.Draft? {
        guard lookupFinished, let lookup else { return nil }
        switch lookup.kind {
        case .word:
            return .init(kind: .word, excerpt: lookup.excerpt, result: .init(definition: answer))
        case .translation:
            return .init(kind: .sentence, excerpt: lookup.excerpt,
                         result: .init(translation: answer, analysis: grammarFavorite?.result.analysis))
        case .analysis:
            return .init(kind: .grammar, excerpt: lookup.excerpt, result: .init(analysis: answer))
        }
    }

    var grammarFavorite: LearningFavorite.Draft? {
        guard let analysis = translationAnalysis else { return nil }
        let text: String
        if analysis.detailsExpanded, analysis.finished {
            text = analysis.answer
        } else if let summary = analysis.summary {
            text = grammarSummaryText(summary)
        } else {
            return nil
        }
        guard !text.isEmpty else { return nil }
        return .init(kind: .grammar, excerpt: analysis.excerpt, result: .init(analysis: text))
    }

    private func grammarSummaryText(_ result: StudyResult) -> String {
        let notes = result.items.map { item in
            "\(item.style?.label ?? "原文") · \(item.quote)\n\(item.detail)"
        }
        return ([result.overview] + notes).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var studyFavorite: LearningFavorite.Draft? {
        if let study, study.kind == .structure, let result = study.result, let target = study.request?.target {
            let text = grammarSummaryText(result)
            guard !text.isEmpty else { return nil }
            return .init(kind: .grammar, excerpt: target, result: .init(analysis: text))
        }
        return phraseFavorite
    }

    var phraseFavorite: LearningFavorite.Draft? {
        guard study?.kind == .phrase, let result = study?.result, let phrase = result.items.first else { return nil }
        let excerpt = TextExcerpt(text: phrase.quote, range: phrase.range, context: "")
        let definition = [result.overview, phrase.detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !definition.isEmpty else { return nil }
        return .init(kind: .phrase, excerpt: excerpt, result: .init(definition: definition))
    }

    var favoritesTitle: String { article.pdfPage == nil ? "本篇收藏" : "本书收藏" }
    var favoriteCount: Int {
        article.pdfPage == nil ? (learningRecord?.favorites.count ?? 0)
            : bookLearningRecords.reduce(0) { $0 + $1.favorites.count }
    }

    var favorites: [LearningFavoriteEntry] {
        if article.pdfPage == nil {
            guard let record = learningRecord else { return [] }
            return record.favorites.map { LearningFavoriteEntry(favorite: $0, pdfSource: nil) }
        }
        return bookLearningRecords.flatMap { record -> [LearningFavoriteEntry] in
            guard let page = record.pdfPage else { return [] }
            return record.favorites.map { favorite in
                let source = "PDF 第 \(page.sourcePage(at: favorite.range.location) + 1) 页"
                let location = page.chapter.map { "\($0.chapter.label) · \(source)" } ?? source
                return LearningFavoriteEntry(favorite: favorite, pdfSource: location)
            }
        }.sorted { $0.favorite.createdAt > $1.favorite.createdAt }
    }

    func isFavorite(_ draft: LearningFavorite.Draft) -> Bool {
        savedFavoriteID(for: draft) != nil
    }

    func toggleFavorite(_ draft: LearningFavorite.Draft) throws {
        if let id = savedFavoriteID(for: draft) {
            try removeFavorite(id)
        } else {
            try saveFavorite(draft)
        }
    }

    private func savedFavoriteID(for draft: LearningFavorite.Draft) -> String? {
        guard let record = learningRecord, let excerpt = index.excerpt(in: draft.excerpt.range) else { return nil }
        let id = LearningFavorite.id(articleId: record.articleId, kind: draft.kind, range: excerpt.range)
        return record.favorites.first(where: { $0.id == id })?.id
    }

    func saveFavorite(_ draft: LearningFavorite.Draft) throws {
        guard let selected = index.excerpt(in: draft.excerpt.range),
              selected.text == draft.excerpt.text || completedBookSentence(selected).text == draft.excerpt.text,
              let context = index.favoriteContext(for: selected.range) else {
            throw ReaderError.message("无法在当前正文定位这条收藏。")
        }
        var next = try editableLearningRecord()
        let range = selected.range
        let id = LearningFavorite.id(articleId: next.articleId, kind: draft.kind, range: range)
        guard !next.favorites.contains(where: { $0.id == id }) else { return }
        let now = next.touch()
        var favorite = LearningFavorite(favoriteId: id, kind: draft.kind, selectedText: selected.text,
                                        sentence: context.sentence, paragraph: context.paragraph, range: .init(range),
                                        result: draft.result, createdAt: now, updatedAt: now)
        if let ending = article.pdfPage?.sentenceEnding {
            favorite.completePDFSentence(in: article.body, ending: ending)
        }
        next.favorites.append(favorite)
        if let source = library.current, source.learningSource == nil {
            next.importedWebURL = source.sourceURL ?? next.importedWebURL
            weeklyFavorites.stage(favorite: favorite, record: next, file: importedLearning.file(for: source),
                                  webURL: source.sourceURL)
        }
        defer { weeklyFavorites.resume() }
        try saveLearningRecord(next)
    }

    func removeFavorite(_ id: String) throws {
        guard let source = favoriteRecord(containing: id),
              let index = source.record.favorites.firstIndex(where: { $0.id == id }) else { return }
        var next = source.record
        next.favorites.remove(at: index)
        _ = next.touch()
        if source.record.articleId == learningRecord?.articleId {
            try saveLearningRecord(next)
        } else {
            let savedArticle = try next.pdfArticle()
            try importedLearning.save(next, for: savedArticle)
            updateBookLearningRecord(next)
        }
        if next.sourceId == nil { weeklyFavorites.discardPending(favoriteID: id) }
        if shownFavorite?.id == id { shownFavorite = nil }
    }

    func showFavorite(_ id: String) throws {
        guard let source = favoriteRecord(containing: id) else { return }
        let favorite = source.favorite
        if source.record.articleId != learningRecord?.articleId {
            let savedArticle = try source.record.pdfArticle()
            let savedIndex = ReadingIndex(savedArticle.body)
            _ = try favoriteExcerpt(favorite, in: savedIndex)
            try adopt(savedArticle)
        }
        let excerpt = try favoriteExcerpt(favorite, in: index)
        cancelLookup()
        resetTranslationAnalysis()
        dismissStudy()
        lookup = nil
        shownFavorite = favorite
        selection = excerpt
        jump = ReadingJump(range: excerpt.range, select: true)
        rememberReadingPosition(at: excerpt.range.location)
    }

    private func favoriteRecord(containing id: String) -> (favorite: LearningFavorite, record: LearningRecord)? {
        if let record = learningRecord, let favorite = record.favorites.first(where: { $0.id == id }) {
            return (favorite, record)
        }
        for record in bookLearningRecords {
            if let favorite = record.favorites.first(where: { $0.id == id }) { return (favorite, record) }
        }
        return nil
    }

    private func favoriteExcerpt(_ favorite: LearningFavorite, in index: ReadingIndex) throws -> TextExcerpt {
        guard favorite.range.location >= 0, favorite.range.length > 0,
              favorite.range.location <= index.text.utf16.count,
              favorite.range.length <= index.text.utf16.count - favorite.range.location else {
            throw ReaderError.message("收藏的位置超出了当前正文。")
        }
        let range = NSRange(location: favorite.range.location, length: favorite.range.length)
        guard let excerpt = index.excerpt(in: range), excerpt.range == range,
              excerpt.text.utf8.elementsEqual((favorite.anchorText ?? favorite.selectedText).utf8) else {
            throw ReaderError.message("无法在当前正文定位这条收藏。")
        }
        return excerpt
    }

    func completeReading(difficulty: ReadingDifficulty, feedback: String, reason: ReadingDifficultyReason? = nil) throws {
        var next = try editableLearningRecord()
        let now = next.touch()
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        next.reading = ReadingFeedback(status: .completed, completedAt: now, difficulty: difficulty, difficultyReason: reason,
                                       feedback: text.isEmpty ? nil : text)
        try saveLearningRecord(next)
        if let position = savedPositions[positionKey] {
            saveReadingPosition(SavedReadingPosition(sentenceStart: position.sentenceStart, completed: true,
                                                     chapterOffset: position.chapterOffset))
        }
    }

    private func editableLearningRecord() throws -> LearningRecord {
        guard !isLoadingLearningRecord else { throw ReaderError.message("正在读取本篇学习记录，请稍后再试。") }
        if article.learningSource == nil {
            return try learningRecord ?? importedLearning.load(for: article) ?? LearningRecord(article: article, now: .now)
        }
        var record = try learningRecord ?? learningStore.load(for: article) ?? LearningRecord(article: article, now: Date())
        if record.sourceId == nil { _ = record.updateSource(from: article) }
        return record
    }

    private func saveLearningRecord(_ record: LearningRecord) throws {
        if article.learningSource == nil {
            try importedLearning.save(record, for: article)
            updateBookLearningRecord(record)
        } else {
            try learningStore.save(record)
        }
        learningRecord = record
    }

    private func updateBookLearningRecord(_ record: LearningRecord) {
        guard let book = article.pdfPage?.book, record.pdfPage?.book.id == book.id else { return }
        if let index = bookLearningRecords.firstIndex(where: { $0.articleId == record.articleId }) {
            bookLearningRecords[index] = record
        } else {
            bookLearningRecords.append(record)
        }
    }

    private func loadLearningRecord(refreshSource: Bool = false) {
        learningRecordTask?.cancel()
        learningRecord = nil
        let bookID = article.pdfPage?.book.id
        if cachedBookID != bookID { bookLearningRecords = []; cachedBookID = nil }
        isLoadingLearningRecord = false
        if article.learningSource == nil {
            do {
                learningRecord = try importedLearning.load(for: article)
                if let book = article.pdfPage?.book, cachedBookID != book.id {
                    bookLearningRecords = try importedLearning.records(for: book)
                    cachedBookID = book.id
                }
                if library.current != nil, learningRecord?.importedLegacy != true { migrateLegacyRecord(for: article) }
            } catch {
                notice = "无法读取收藏。\n\(error.localizedDescription)"
            }
            return
        }
        if let backgroundLearningRecords {
            let current = article
            isLoadingLearningRecord = true
            learningRecordTask = Task { [weak self] in
                let result: Result<LearningRecordScan, Error>
                do { result = .success(try await backgroundLearningRecords.scan(for: current)) }
                catch { result = .failure(error) }
                guard let self, !Task.isCancelled else { return }
                isLoadingLearningRecord = false
                updateLearningRecord(result, refreshSource: refreshSource)
            }
        } else {
            updateLearningRecord(Result { try learningStore.scan(for: article) }, refreshSource: refreshSource)
        }
    }

    private func migrateLegacyRecord(for source: Article) {
        let key = importedLearning.key(for: source)
        guard checkedLegacyRecords.insert(key).inserted else { return }
        let loader = backgroundLegacyRecords
        Task { [weak self] in
            let legacy: LearningRecord?
            do { legacy = try await loader.load(for: source) }
            catch {
                self?.checkedLegacyRecords.remove(key)
                return
            }
            guard let self else { return }
            do {
                guard let record = try importedLearning.importLegacy(legacy, for: source) else { return }
                if article.learningSource == nil, importedLearning.key(for: article) == key {
                    learningRecord = record
                }
                updateBookLearningRecord(record)
            } catch {
                checkedLegacyRecords.remove(key)
            }
        }
    }

    private func updateLearningRecord(_ result: Result<LearningRecordScan, Error>, refreshSource: Bool) {
        do {
            let scan = try result.get()
            if !scan.unreadable.isEmpty {
                notice = "以下学习记录无法读取，原文件已保留：\n" + scan.unreadable.joined(separator: "\n")
            }
            guard var record = scan.record else { return }
            learningRecord = record
            if refreshSource, record.updateSource(from: article) {
                _ = record.touch()
                try saveLearningRecord(record)
            }
        } catch {
            notice = "无法更新本篇学习记录。\n\(error.localizedDescription)"
        }
    }

    func translateSentence(containing excerpt: TextExcerpt) {
        translateSentence(at: excerpt.range.location)
    }

    @discardableResult
    func clickText(at position: Int, wholeSentence: Bool) -> Bool {
        if article.pdfPage != nil, let paragraph = index.paragraph(at: position), !canAssist(paragraph) { return false }
        if wholeSentence {
            return translateSentence(at: position)
        }
        guard let word = WordLookup.excerpt(at: position, in: article.body) else { return false }
        rememberReadingPosition(at: position)
        selectQuestionReference(word)
        lookUp(.word, excerpt: word)
        return true
    }

    @discardableResult
    private func translateSentence(at position: Int) -> Bool {
        guard let sentence = index.sentence(at: position), canAssist(sentence) else { return false }
        selection = sentence
        jump = ReadingJump(range: sentence.range, select: true)
        rememberReadingPosition(at: position)
        selectQuestionReference(sentence)
        lookUp(.translation, excerpt: sentence)
        return true
    }

    var assistantWordTarget: TextExcerpt? {
        if let selection, !canAssist(selection) { return nil }
        if let selection, let word = shortPhrase(in: selection.range) { return word }
        return lastAssistantWord
    }

    var assistantSource: TextExcerpt? {
        guard let target = study?.request?.target ?? lookup?.excerpt else { return nil }
        return completedBookSentence(index.sentence(at: target.range.location) ?? target)
    }

    var assistantSentenceTarget: TextExcerpt? {
        if let selection {
            guard canAssist(selection), let sentence = index.sentence(at: selection.range.location), canAssist(sentence) else { return nil }
            return sentence
        }
        return assistantSource
    }

    func assistantQuestionReference(currentOnly: Bool, spoken: TextExcerpt?) -> AssistantQuestionReference? {
        let current = selection ?? spoken
        let target = currentOnly ? current ?? index.sentence(at: readingPosition)
            : study?.request?.focusedWord ?? selection ?? study?.request?.target ?? lookup?.excerpt ?? spoken
        return target.flatMap(questionReference(for:))
    }

    func selectQuestionReference(_ target: TextExcerpt) {
        guard let reference = questionReference(for: target) else { return }
        questionSelection = AssistantQuestionSelection(reference: reference)
    }

    private func questionReference(for target: TextExcerpt) -> AssistantQuestionReference? {
        guard let excerpt = index.excerpt(in: target.range), canAssist(excerpt) else { return nil }
        let sentence = index.sentence(at: excerpt.range.location)
        let insideSentence = sentence.map { NSIntersectionRange($0.range, excerpt.range) == excerpt.range } ?? false
        let passage = completedBookSentence(insideSentence ? sentence ?? excerpt : excerpt)
        guard canAssist(passage) else { return nil }
        let source = AssistantQuestionSource(title: article.title,
            location: .text(material: positionKey, range: passage.range, pdf: article.pdfPage))
        return AssistantQuestionReference(passage: passage.text, focus: passage.text == excerpt.text ? nil : excerpt.text,
                                          surrounding: index.context(around: passage.range), source: source)
    }

    func locateQuestionSource(_ reference: AssistantQuestionReference, excerpt: NSRange?) async throws {
        guard case let .text(material, originalRange, pdf)? = reference.source?.location else { return }
        let target: Article?
        if material == positionKey {
            target = article
        } else if let pdf {
            let openingVersion = articleVersion
            if let chapter = pdf.chapter {
                target = try await pdfBooks.chapterArticle(for: pdf.book, chapter: chapter.chapter,
                                                          englishOnly: pdf.englishOnly, join: chapter.join)
            } else {
                target = try await pdfBooks.article(for: pdf.book, at: pdf.index, englishOnly: pdf.englishOnly)
            }
            try Task.checkCancellation()
            guard openingVersion == articleVersion else { throw CancellationError() }
        } else {
            target = (history.map(\.article) + [Article.sample]).first { SavedReadingPosition.key(for: $0) == material }
        }
        guard let target, let range = reference.sourceRange(in: target.body, at: originalRange, excerpt: excerpt) else {
            throw ReaderError.message("找不到这条问答的原文位置。原文可能已删除或修改。")
        }
        if material != positionKey { try adopt(target) }
        jump = ReadingJump(range: range, select: true)
    }

    var hasEnglishSelection: Bool { selection.map(canAssist) == true }
    var hasEnglishReadingText: Bool { article.pdfPage == nil || !PDFBookText.englishOnly(article.body).isEmpty }

    func canAssist(_ excerpt: TextExcerpt) -> Bool {
        article.pdfPage == nil || PDFBookText.isEnglish(excerpt.text)
    }

    func shortPhrase(in range: NSRange) -> TextExcerpt? {
        guard let selected = index.excerpt(in: range), canAssist(selected),
              let sentence = index.sentence(at: selected.range.location),
              canAssist(sentence), NSIntersectionRange(sentence.range, selected.range) == selected.range else { return nil }
        let local = NSRange(location: selected.range.location - sentence.range.location,
                            length: selected.range.length)
        let tokens = SubtitleWordTokenizer.words(in: sentence.text)
        guard let first = tokens.first(where: { NSIntersectionRange($0.range, local).length > 0 }),
              let last = tokens.last(where: { NSIntersectionRange($0.range, local).length > 0 }),
              let phrase = SubtitleWordTokenizer.selection(in: sentence.text, from: first, to: last) else { return nil }
        return TextExcerpt(text: phrase.text,
                           range: NSRange(location: sentence.range.location + phrase.range.location, length: phrase.range.length),
                           context: sentence.text, contextWordRange: phrase.range)
    }

    func locate(_ range: NSRange) {
        jump = ReadingJump(range: range)
    }

    func sentencesForListening(to excerpt: TextExcerpt) -> [TextExcerpt] {
        guard let verified = index.excerpt(in: excerpt.range), canAssist(verified) else { return [] }
        return index.sentences(in: verified).map(completedBookSentence)
    }

    func listeningContinuation(after excerpt: TextExcerpt) -> [TextExcerpt] {
        index.articleSentences().filter { $0.range.location >= NSMaxRange(excerpt.range) && canAssist($0) }
            .map(completedBookSentence)
    }

    func articleForListening(fromHere: Bool) -> (sentences: [TextExcerpt], start: Int) {
        let sentences = index.articleSentences().filter(canAssist).map(completedBookSentence)
        let position = selection?.range.location ?? readingPosition
        let start = fromHere ? sentences.firstIndex { NSMaxRange($0.range) > position } ?? 0 : 0
        return (sentences, start)
    }

    private func completedBookSentence(_ excerpt: TextExcerpt) -> TextExcerpt {
        guard let ending = article.pdfPage?.sentenceEnding,
              NSMaxRange(excerpt.range) == article.body.utf16.count,
              canAssist(excerpt), !PDFBookText.hasSentenceEnding(excerpt.text),
              let local = index.excerpt(in: excerpt.range), local.text == excerpt.text else { return excerpt }
        return TextExcerpt(text: excerpt.text + " " + ending, range: excerpt.range, context: excerpt.context)
    }

    func listeningParagraph(for sentence: NSRange) -> NSRange {
        index.paragraph(at: sentence.location)?.range ?? sentence
    }

    func canShowTranslationBelow(_ lookup: LookupRequest) -> Bool {
        translationSentence(lookup) != nil
    }

    func isShowingTranslationBelow(_ lookup: LookupRequest) -> Bool {
        guard let sentence = translationSentence(lookup) else { return false }
        return inlineTranslation == InlineTranslation(sentence: sentence.range, text: answer)
    }

    func toggleInlineTranslation(for lookup: LookupRequest) {
        guard !isLookingUp, lookupError == nil, !answer.isEmpty, let sentence = translationSentence(lookup) else { return }
        let next = InlineTranslation(sentence: sentence.range, text: answer)
        if inlineTranslation == next { closeInlineTranslation(); return }
        inlineTranslation = next
        jump = ReadingJump(range: sentence.range, showInline: true)
    }

    func closeInlineTranslation() {
        inlineTranslation = nil
    }

    private func translationSentence(_ lookup: LookupRequest) -> TextExcerpt? {
        guard lookup.kind == .translation, lookup.excerpt.text.utf16.count <= 450,
              let excerpt = index.excerpt(in: lookup.excerpt.range),
              let sentence = index.sentence(at: excerpt.range.location),
              NSIntersectionRange(sentence.range, excerpt.range) == excerpt.range else { return nil }
        return sentence
    }

    func setAssistedReading(_ enabled: Bool) {
        assistedReading = enabled
        if enabled { refreshHints() }
        else { resetHints() }
    }

    func didScroll(to position: Int, saveForResume: Bool = true) {
        readingPosition = position
        if saveForResume { rememberReadingPosition(at: position) }
        if assistedReading { refreshHints() }
    }

    private func rememberReadingPosition(at position: Int) {
        guard library.current != nil else { return }
        let chapterAnchor = article.pdfPage?.chapter?.anchors.last(where: { $0.offset <= position })?.offset
        if let rememberedSentence, NSLocationInRange(position, rememberedSentence),
           max(rememberedSentence.location, chapterAnchor ?? 0) == (savedPositions[positionKey]?.chapterOffset ?? rememberedSentence.location) { return }
        guard let sentence = index.sentence(at: position) else { return }
        let completed = learningRecord?.reading.status == .completed || savedPositions[positionKey]?.completed == true
        let chapterOffset = chapterAnchor.map { max(sentence.range.location, $0) }
        if saveReadingPosition(SavedReadingPosition(sentenceStart: sentence.range.location, completed: completed,
                                                    chapterOffset: chapterOffset)) {
            rememberedSentence = sentence.range
        }
    }

    @discardableResult
    private func saveReadingPosition(_ position: SavedReadingPosition) -> Bool {
        guard !recoveryNeeded.contains(.positions) else { return false }
        if savedPositions[positionKey] == position { return true }
        var positions = savedPositions
        positions[positionKey] = position
        do {
            try store.savePositions(positions)
            savedPositions = positions
            return true
        } catch {
            recoveryNeeded.insert(.positions)
            notice = "阅读进度未写入，请在历史记录中恢复。\n\(error.localizedDescription)"
            return false
        }
    }

    private func restoreReadingPosition() {
        positionKey = SavedReadingPosition.key(for: article)
        rememberedSentence = nil
        readingPosition = 0
        guard let saved = savedPositions[positionKey] else { return }
        let position = saved.chapterOffset ?? saved.sentenceStart
        guard position >= 0, position < article.body.utf16.count,
              let sentence = index.sentence(at: position) else { return }
        rememberedSentence = sentence.range
        readingPosition = saved.chapterOffset == nil ? sentence.range.location : position
        let range = position == sentence.range.location || saved.chapterOffset == nil
            ? sentence.range : NSRange(location: position, length: 0)
        jump = ReadingJump(range: range, alignToTop: true)
    }

    func openStudy(_ kind: StudyKind, at source: TextExcerpt? = nil, focusWord: TextExcerpt? = nil) {
        let focus = source ?? selection ?? focusedWord ?? study?.request?.target
        if let focus, !canAssist(focus) { return }
        let word = kind == .phrase ? (focusWord ?? focusedWord) : (kind == .reference ? referenceWord : nil)
        dismissStudy()
        cancelLookup()
        if kind == .phrase && word == nil { return }
        shownFavorite = nil
        let position = focus?.range.location ?? readingPosition
        let id = UUID()
        do {
            let request = try index.request(kind, at: position, selection: selection, word: word)
            guard canAssist(request.target) else { return }
            study = ActiveStudy(id: id, kind: kind, request: request, isLoading: true)
            let settings = modelSettings
            studyTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let answer = try await self.studyResult(for: request, using: settings)
                    guard self.study?.id == id, !Task.isCancelled else { return }
                    self.study?.result = answer
                    self.study?.isLoading = false
                    if kind == .reference, let referring = answer.items.first(where: { $0.style == .referring }) {
                        self.locate(referring.range)
                    }
                } catch {
                    guard self.study?.id == id, !Task.isCancelled else { return }
                    self.study?.error = Self.connectionMessage(error)
                    self.study?.isLoading = false
                }
            }
        } catch {
            study = ActiveStudy(id: id, kind: kind, error: error.localizedDescription)
        }
    }

    func revealStudyAnswer() {
        study?.answerRevealed = true
    }

    var referenceWord: TextExcerpt? {
        guard let word = focusedWord, Self.referenceWords.contains(word.text.lowercased()) else { return nil }
        return word
    }

    private static let referenceWords: Set<String> = [
        "it", "its", "this", "that", "these", "those", "he", "his", "she", "her", "they", "them", "their",
        "which", "who", "whom", "whose", "former", "latter", "such", "so", "one", "ones"
    ]

    func dismissStudy() {
        studyTask?.cancel()
        study = nil
    }

    private func refreshHints() {
        guard let paragraph = index.paragraph(at: readingPosition), canAssist(paragraph) else {
            if hintScope != nil { resetHints() }
            return
        }
        guard paragraph.range != hintScope else { return }
        hintTask?.cancel()
        let scope = paragraph.range
        hintScope = scope
        hints = nil
        hintStatus = "正在找本段难点…"
        let settings = modelSettings
        hintTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(380))
                let request = try self.index.request(.hints, at: scope.location)
                let answer = try await self.studyResult(for: request, using: settings)
                guard self.hintScope == scope, !Task.isCancelled else { return }
                self.hints = answer
                self.hintStatus = answer.items.isEmpty ? "本段暂无重点提示" : "本段有 \(answer.items.count) 处助读提示"
            } catch {
                guard self.hintScope == scope, !Task.isCancelled else { return }
                self.hintStatus = "本段提示暂不可用"
            }
        }
    }

    private func resetHints() {
        hintTask?.cancel()
        hintScope = nil
        hints = nil
        hintStatus = nil
    }

    private func studyResult(for request: StudyRequest, using settings: ModelSettings) async throws -> StudyResult {
        let (client, model) = try await settings.clientAndModel()
        let key = StudyCacheKey(endpoint: settings.address, model: model, request: request)
        try Task.checkCancellation()
        if let cached = studyCache[key] { return cached }
        let answer = try await client.study(request, model: model)
        try Task.checkCancellation()
        if studyCache.count >= 120 { studyCache.removeAll(keepingCapacity: true) }
        studyCache[key] = answer
        return answer
    }

    func lookUp(_ kind: LookupKind, excerpt: TextExcerpt? = nil) {
        guard let excerpt = excerpt ?? selection, canAssist(excerpt) else { return }
        if kind == .word { lastAssistantWord = excerpt }
        dismissStudy()
        shownFavorite = nil
        let request = LookupRequest(kind: kind, excerpt: excerpt,
                                    surrounding: kind == .word ? nil : index.context(around: excerpt.range))
        let modelRequest = LookupRequest(kind: kind,
                                        excerpt: kind == .word ? excerpt : completedBookSentence(excerpt),
                                        surrounding: request.surrounding)
        lookupTask?.cancel()
        resetTranslationAnalysis()
        let id = UUID()
        generation = id
        lookup = request
        answer = ""
        lookupError = nil
        lookupFinished = false
        if kind != .word, excerpt.text.utf16.count > 4_500 {
            isLookingUp = false
            lookupError = "选区超过 4,500 字符，请缩小到一段后重试。"
            return
        }

        let settings = modelSettings
        isLookingUp = true
        lookupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == id { self.isLookingUp = false }
            }
            do {
                let result = try await self.lookupResult(for: modelRequest, using: settings) { partial in
                    if self.generation == id { self.answer = partial }
                }
                guard self.generation == id, !Task.isCancelled else { return }
                self.answer = result
                self.lookupFinished = true
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.lookupError = Self.connectionMessage(error)
            }
        }
    }

    func cancelLookup() {
        lookupTask?.cancel()
        generation = nil
        isLookingUp = false
    }

    func toggleTranslationAnalysis(for translation: LookupRequest) {
        guard lookup == translation, translation.kind == .translation else { return }
        if translationAnalysis == nil {
            translationAnalysis = TranslationAnalysis(excerpt: translation.excerpt)
            summarizeTranslation(translation)
        } else {
            translationAnalysis?.isExpanded.toggle()
        }
    }

    func summarizeTranslation(_ translation: LookupRequest) {
        guard lookup == translation, let analysis = translationAnalysis else { return }
        translationSummaryTask?.cancel()
        translationAnalysis?.isSummarizing = true
        translationAnalysis?.summaryError = nil
        let settings = modelSettings
        translationSummaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = try self.index.request(.structure, at: analysis.excerpt.range.location)
                request.compactStructure = true
                request.surrounding = self.index.context(around: request.target.range)
                let summary = try await self.studyResult(for: request, using: settings)
                guard self.translationAnalysis?.id == analysis.id, !Task.isCancelled else { return }
                self.translationAnalysis?.summary = summary
                self.translationAnalysis?.summaryRange = request.target.range
            } catch {
                guard self.translationAnalysis?.id == analysis.id, !Task.isCancelled else { return }
                self.translationAnalysis?.summaryError = Self.connectionMessage(error)
            }
            guard self.translationAnalysis?.id == analysis.id, !Task.isCancelled else { return }
            self.translationAnalysis?.isSummarizing = false
        }
    }

    func toggleTranslationDetails(_ translation: LookupRequest) {
        guard lookup == translation, let analysis = translationAnalysis else { return }
        translationAnalysis?.detailsExpanded.toggle()
        if !analysis.detailsExpanded, !analysis.finished, !analysis.isLoading, analysis.error == nil {
            analyzeTranslation(translation)
        }
    }

    func analyzeTranslation(_ translation: LookupRequest) {
        guard lookup == translation, let analysis = translationAnalysis else { return }
        stopTranslationAnalysis()
        let excerpt = translation.excerpt
        translationAnalysis?.answer = ""
        translationAnalysis?.finished = false
        translationAnalysis?.error = nil
        if excerpt.text.utf16.count > 4_500 {
            translationAnalysis?.isLoading = false
            translationAnalysis?.error = "选区超过 4,500 字符，请缩小到一段后重试。"
            return
        }

        let request = LookupRequest(kind: .analysis, excerpt: excerpt, includeTranslation: false, surrounding: translation.surrounding)
        let settings = modelSettings
        translationAnalysis?.isLoading = true
        translationAnalysisTask = Task { [weak self, id = analysis.id] in
            guard let self else { return }
            defer {
                if self.translationAnalysis?.id == id, !Task.isCancelled { self.translationAnalysis?.isLoading = false }
            }
            do {
                let result = try await self.lookupResult(for: request, using: settings) { partial in
                    guard self.translationAnalysis?.id == id, !Task.isCancelled else { return }
                    self.translationAnalysis?.answer = partial
                }
                guard self.translationAnalysis?.id == id, !Task.isCancelled else { return }
                self.translationAnalysis?.answer = result
                self.translationAnalysis?.finished = true
            } catch {
                guard self.translationAnalysis?.id == id, !Task.isCancelled else { return }
                self.translationAnalysis?.error = Self.connectionMessage(error)
            }
        }
    }

    func stopTranslationAnalysis() {
        translationAnalysisTask?.cancel()
        translationAnalysis?.isLoading = false
    }

    private func resetTranslationAnalysis() {
        translationSummaryTask?.cancel()
        stopTranslationAnalysis()
        translationAnalysis = nil
    }

    private func lookupResult(for request: LookupRequest, using settings: ModelSettings,
                              update: @escaping (String) -> Void) async throws -> String {
        let (client, model) = try await settings.clientAndModel()
        try Task.checkCancellation()
        let key = CacheKey(endpoint: settings.address, model: model, request: request)
        if let cached = cache[key] { return cached }
        let result = try await client.stream(request, model: model, update: update)
        try Task.checkCancellation()
        if cache.count >= 200 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    private func adopt(_ next: Article, refreshLearningSource: Bool = false) throws {
        var updated = library
        updated.open(next)
        try saveLibrary(updated)
        display(next, refreshLearningSource: refreshLearningSource)
    }

    private func display(_ next: Article, refreshLearningSource: Bool) {
        cancelLookup()
        resetTranslationAnalysis()
        dismissStudy()
        resetHints()
        studyCache.removeAll()
        inlineTranslation = nil
        jump = nil
        selection = nil
        questionSelection = nil
        lastAssistantWord = nil
        lookup = nil
        shownFavorite = nil
        answer = ""
        lookupError = nil
        lookupFinished = false
        cache.removeAll()
        index = ReadingIndex(next.body)
        loadLearningRecord(refreshSource: refreshLearningSource)
        restoreReadingPosition()
        articleVersion = UUID()
        if assistedReading { refreshHints() }
    }

    private func saveLibrary(_ next: ArticleLibrary) throws {
        guard !recoveryNeeded.contains(.library) else { throw ReaderError.message("请先在历史记录中恢复文章历史。") }
        do {
            try store.save(next)
        } catch {
            recoveryNeeded.insert(.library)
            throw ReaderError.message("无法保存文章记录。\n\(error.localizedDescription)")
        }
        library = next
    }

    func fetchLanguageAnswer(_ request: LookupRequest, update: @escaping (String) -> Void) async throws -> String {
        try await lookupResult(for: request, using: modelSettings, update: update)
    }

    func answerQuestion(_ request: AssistantQuestionRequest, update: @escaping (String) -> Void) async throws -> String {
        let (client, model) = try await modelSettings.clientAndModel()
        return try await client.answer(request, model: model, update: update)
    }

    func answerPractice(_ request: AssistantPracticeRequest) async throws -> String {
        let (client, model) = try await modelSettings.clientAndModel()
        return try await client.practice(request, model: model)
    }

    func fetchLanguageStudy(_ request: StudyRequest) async throws -> StudyResult {
        try await studyResult(for: request, using: modelSettings)
    }

    static func connectionMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return "LM Studio 响应超时。检查服务器和模型状态后重试。"
            }
            return "无法连接 LM Studio。请在 LM Studio 的 Developer 页面启动服务器，并检查设置中的地址。"
        }
        if error is DecodingError {
            return "LM Studio 返回了无法识别的结果。请检查服务器地址、接口和模型设置。"
        }
        return error.localizedDescription
    }

    private struct CacheKey: Hashable {
        let endpoint: String
        let model: String
        let request: LookupRequest
    }

    private struct StudyCacheKey: Hashable {
        let endpoint: String
        let model: String
        let request: StudyRequest
    }

    private var modelSettings: ModelSettings {
        ModelSettings(address: endpoint, preferred: preferredModel, known: models)
    }

    private struct ModelSettings {
        let address: String
        let preferred: String
        let known: [String]

        func clientAndModel() async throws -> (LMStudioClient, String) {
            let client = try LMStudioClient(endpoint: address)
            if preferred.isEmpty {
                if let first = known.first { return (client, first) }
                return (client, try await client.models()[0])
            }
            guard known.isEmpty || known.contains(preferred) else {
                throw ReaderError.message("所选模型不在服务器列表中，请在设置中重新选择。")
            }
            return (client, preferred)
        }
    }

    struct TranslationAnalysis {
        let id = UUID()
        let excerpt: TextExcerpt
        var isExpanded = true
        var summary: StudyResult?
        var summaryRange: NSRange?
        var isSummarizing = false
        var summaryError: String?
        var detailsExpanded = false
        var answer = ""
        var isLoading = false
        var finished = false
        var error: String?
    }

    struct ActiveStudy {
        let id: UUID
        let kind: StudyKind
        var request: StudyRequest?
        var result: StudyResult?
        var error: String?
        var isLoading = false
        var answerRevealed = false
    }
}
