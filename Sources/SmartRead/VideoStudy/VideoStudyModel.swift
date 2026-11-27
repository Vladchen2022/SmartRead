import Combine
import Foundation
import OSLog

enum SubtitleLanguage: Hashable, Sendable {
    case english
    case chinese
}

struct SentenceBoundaryEdit: Identifiable {
    let cue: SubtitleCue
    let decision: SubtitleBoundaryDecision
    var id: UUID { cue.id }
    var title: String {
        let text = String(cue.text.replacingOccurrences(of: "\n", with: " ").prefix(38))
        return decision == .split ? "在「\(text)」前拆开" : "合并下一段「\(text)」"
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case analysis = "整句"
    case word = "查词"
    case phrase = "搭配"
    case transcript = "文稿"

    var id: String { rawValue }
}

enum NoteConfirmationState: Equatable {
    case idle
    case writing
    case saved(String)
    case pending(String)
}

struct NoteMigrationPreview {
    let destination: String
    let entries: [LearningActivity]
}

struct SentenceLoop: Equatable, Sendable {
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let english: String
}

@MainActor
final class VideoStudyModel: ObservableObject {
    let playerController: PlayerController

    @Published private(set) var englishCues: [SubtitleCue] = [] {
        didSet { subtitleTrackChanged(.english) }
    }
    @Published private(set) var englishReadingMode: EnglishReadingMode
    @Published private(set) var chineseCues: [SubtitleCue] = [] {
        didSet { subtitleTrackChanged(.chinese) }
    }
    @Published private(set) var activeEnglish: [SubtitleCue] = []
    @Published private var positionedListeningMark: SubtitleSentenceContext?
    private var replayStarted: ((PlaybackSpeed) -> Void)?
    @Published private(set) var activeChinese: [SubtitleCue] = []
    @Published private(set) var selectedSubtitle: SubtitleSelection?
    @Published private(set) var analysisState: AnalysisState = .idle
    @Published private(set) var assistantGrammarExpanded = false
    @Published private(set) var selectedWordRequest: WordLookupRequest?
    @Published private(set) var questionSelection: AssistantQuestionSelection?
    @Published private(set) var wordLookupState: WordLookupState = .idle
    @Published private(set) var currentSourceVideoURL: URL?
    @Published private(set) var embeddedSubtitleTracks: [EmbeddedSubtitleTrack] = []
    @Published private(set) var selectedEnglishEmbeddedTrackID: Int?
    @Published private(set) var selectedChineseEmbeddedTrackID: Int?
    @Published private(set) var isPreparingMedia = false
    @Published private(set) var mediaPreparationMessage = ""
    @Published private(set) var recentVideos: [VideoLearningRecord] = []
    @Published private(set) var currentVideoRecord: VideoLearningRecord?
    @Published private(set) var obsidianVaultPath = ""
    @Published private(set) var obsidianSyncStatus = ""
    @Published private(set) var noteMigrationPreview: NoteMigrationPreview?
    @Published private(set) var sentenceNoteState: NoteConfirmationState = .idle
    @Published private(set) var wordNoteState: NoteConfirmationState = .idle
    @Published var sidebarMode: SidebarMode = .analysis
    @Published var alertMessage: String?
    @Published var subtitleNotice: String?
    @Published private(set) var sentenceLoop: SentenceLoop?
    @Published private(set) var isListeningFirst = false
    @Published private(set) var revealStage: SubtitleRevealStage = .hidden
    @Published private(set) var listeningPractice: ListeningPractice?
    @Published private(set) var hasFinishedListeningPass = false
    @Published private(set) var calibration = SubtitleCalibration() {
        didSet { rebuildBilingualAlignment() }
    }
    @Published var transcriptSearch = "" { didSet { updateTranscriptMatches() } }
    @Published private(set) var filteredTranscript: [SubtitleCue] = []

    private let modelSettings: () -> (endpoint: String, model: String)
    private var selectedModelID: String { modelSettings().model }

    private let aiService: any AIServiceProtocol
    private let wordLookupService: any WordLookupServiceProtocol
    private let embeddedSubtitleService: any EmbeddedSubtitleServiceProtocol
    private let obsidianExportService: any ObsidianExportServiceProtocol
    private let noteWriter: DailyNoteWriter
    private var noteSyncTask: Task<Void, Never>?
    private let repository: LearningRepository?
    private let defaults: UserDefaults
    private let legacyExportDestination: String
    private var authorizedObsidianDirectory: String
    private var englishTimeline = SubtitleTimeline(cues: [])
    private var readingTimeline = SubtitleReadingTimeline(cues: [])
    private var bilingualAlignment = BilingualSubtitleAlignment(groups: [], chineseCues: [])
    private var chineseTimeline = SubtitleTimeline(cues: [])
    private var activeTrackKeys: [SubtitleLanguage: String] = [:]
    private var sentenceBoundaries: [String: SubtitleBoundaryDecision] = [:]
    private var transcriptIndex: [(cue: SubtitleCue, chinese: String)] = []
    private var transcriptChinese: [UUID: String] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var analysisTask: Task<Void, Never>?
    private var wordLookupTask: Task<Void, Never>?
    private var wordLookupID = UUID()
    private var wordActivityDraft: LearningActivityDraft?
    private var sentenceActivityDraft: LearningActivityDraft?
    private var cachedSentenceModelID = ""
    private var confirmedSentenceHandle: LearningActivityHandle?
    private var confirmedWordHandle: LearningActivityHandle?
    private var cachedWordModelID = ""
    private var activeWordModelID = ""
    private var activeSentenceModelID = ""
    private var analysisRequestID = UUID()
    private let activityNow: () -> Date
    private let activityTimeZone: TimeZone
    private var mediaLoadTask: Task<Void, Never>?
    private var englishSubtitleTask: Task<Void, Never>?
    private var chineseSubtitleTask: Task<Void, Never>?
    private var englishSubtitleGeneration = UUID()
    private var chineseSubtitleGeneration = UUID()
    private var userSelectedEnglishSubtitle = false
    private var userSelectedChineseSubtitle = false
    private var sentenceLoopRestartTask: Task<Void, Never>?
    private var listeningBoundaryTask: Task<Void, Never>?
    private var listeningPlaybackGeneration = UUID()
    private var mediaLoadID = UUID()
    private var isRestartingSentenceLoop = false
    private var englishSubtitleKind: StoredSubtitleKind = .automatic
    private var chineseSubtitleKind: StoredSubtitleKind = .automatic
    private var englishExternalSubtitleURL: URL?
    private var chineseExternalSubtitleURL: URL?
    private var pendingAudioTrackID: Int32?
    private var totalWatchedMilliseconds: Int64 = 0
    private var lastSavedVideoState: VideoLearningStateDraft?
    private var watchAccountingStartedAt: Date?
    @Published private var autoplayAfterLoad = true
    private let playbackLog = Logger(subsystem: "local.smartread.reader", category: "PlaybackState")

    init(
        playerController: PlayerController? = nil,
        aiService: any AIServiceProtocol = LMStudioService(),
        wordLookupService: any WordLookupServiceProtocol = LMStudioService(),
        embeddedSubtitleService: any EmbeddedSubtitleServiceProtocol = EmbeddedSubtitleService(),
        obsidianExportService: any ObsidianExportServiceProtocol = ObsidianExportService(),
        repository: LearningRepository? = nil,
        defaults: UserDefaults = .standard,
        modelSettings: @escaping () -> (endpoint: String, model: String) = { (LMStudioClient.defaultEndpoint, "") },
        activityNow: @escaping () -> Date = { Date() },
        activityTimeZone: TimeZone = .autoupdatingCurrent
    ) {
        let playerController = playerController ?? PlayerController()
        self.playerController = playerController
        self.modelSettings = modelSettings
        self.aiService = aiService
        self.wordLookupService = wordLookupService
        self.embeddedSubtitleService = embeddedSubtitleService
        self.obsidianExportService = obsidianExportService
        self.noteWriter = DailyNoteWriter(service: obsidianExportService)
        self.defaults = defaults
        self.englishReadingMode = defaults.string(forKey: Keys.englishReadingMode)
            .flatMap(EnglishReadingMode.init(rawValue:)) ?? .sentence
        self.activityNow = activityNow
        self.activityTimeZone = activityTimeZone
        self.obsidianVaultPath = defaults.string(
            forKey: Keys.obsidianVaultPath
        ) ?? ""
        let previousVault = defaults.string(forKey: Keys.obsidianVaultPath) ?? ""
        let legacyDestination = defaults.string(forKey: Keys.legacyExportDestination)
            ?? (previousVault.isEmpty ? "" : ((try? ObsidianExportService.verifiedDestination(
                for: URL(fileURLWithPath: previousVault))) ?? ""))
        self.legacyExportDestination = legacyDestination
        self.authorizedObsidianDirectory = defaults.string(forKey: Keys.authorizedObsidianDirectory)
            ?? (previousVault.isEmpty ? "" : ((try? ObsidianExportService.verifiedDestination(
                for: URL(fileURLWithPath: previousVault))) ?? ""))
        defaults.set(legacyDestination, forKey: Keys.legacyExportDestination)
        if !authorizedObsidianDirectory.isEmpty {
            defaults.set(authorizedObsidianDirectory, forKey: Keys.authorizedObsidianDirectory)
        }
        if let repository {
            self.repository = repository
        } else {
            do {
                self.repository = try LearningRepository.openSmartReadLibrary(defaults: defaults)
            } catch {
                self.repository = nil
                self.alertMessage = error.localizedDescription
            }
        }

        playerController.$confirmedMilliseconds
            .removeDuplicates()
            .sink { [weak self] milliseconds in
                self?.handlePlaybackTime(milliseconds)
            }
            .store(in: &cancellables)

        playerController.$pendingSeekMilliseconds
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        playerController.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                self?.handlePlayingState(isPlaying)
            }
            .store(in: &cancellables)

        playerController.$playbackError
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.alertMessage = message
            }
            .store(in: &cancellables)

        playerController.$availableAudioTracks
            .sink { [weak self] tracks in
                guard let self,
                      let pendingAudioTrackID,
                      tracks.contains(where: { $0.id == pendingAudioTrackID }) else {
                    return
                }
                playerController.selectAudioTrack(pendingAudioTrackID)
                self.pendingAudioTrackID = nil
            }
            .store(in: &cancellables)

        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.saveCurrentVideoState()
            }
            .store(in: &cancellables)

        refreshRecentVideos()

        synchronizeDailyNotes(reportWhenDisabled: false)
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.synchronizeDailyNotes(reportWhenDisabled: false) }
            .store(in: &cancellables)
    }

    isolated deinit {
        analysisTask?.cancel()
        wordLookupTask?.cancel()
        mediaLoadTask?.cancel()
        englishSubtitleTask?.cancel()
        chineseSubtitleTask?.cancel()
        sentenceLoopRestartTask?.cancel()
        listeningBoundaryTask?.cancel()
    }

    var currentVideoName: String? {
        currentSourceVideoURL?.lastPathComponent
    }

    var activeEnglishText: String {
        activeEnglish.map(\.text).joined(separator: "\n")
    }

    var activeChineseText: String {
        activeChinese.map(\.text).joined(separator: "\n")
    }

    var usesSentenceReading: Bool { englishReadingMode == .sentence || isListeningFirst }

    var readingFrame: SubtitleReadingFrame? {
        if let mark = pendingListeningMark, let first = mark.cues.first {
            return SubtitleReadingFrame(context: mark, at: first.startMilliseconds)
        }
        if usesSentenceReading, let practice = listeningPractice {
            let time = hasFinishedListeningPass ? practice.endMilliseconds - 1
                : min(practice.endMilliseconds - 1, max(practice.startMilliseconds, playerController.confirmedMilliseconds))
            return SubtitleReadingFrame(context: practice.context, at: sourceTime(time, for: .english))
        }
        guard usesSentenceReading else { return nil }
        return readingTimeline.frame(at: sourceTime(playerController.confirmedMilliseconds, for: .english))
    }

    private var pendingListeningMark: SubtitleSentenceContext? {
        guard let mark = positionedListeningMark, let first = mark.cues.first,
              !playerController.isPlaying, !playerController.isStarting,
              playerController.pendingSeekMilliseconds == videoTime(for: first) else { return nil }
        return mark
    }

    var displayedEnglishText: String { readingFrame?.text ?? activeEnglishText }

    var displayedChineseText: String {
        guard let frame = readingFrame else { return activeChineseText }
        return bilingualAlignment.text(for: frame.context)
    }

    private func rebuildBilingualAlignment() {
        bilingualAlignment = BilingualSubtitleAlignment(groups: readingTimeline.groups,
            chineseCues: chineseCues, englishTiming: calibration.timing(for: .english),
            chineseTiming: calibration.timing(for: .chinese))
        transcriptIndex = SubtitleTimeline(cues: englishCues).allCues
            .filter { calibratedVideoTime($0.endMilliseconds, for: .english) > 0 }
            .map { ($0, chineseText(for: [$0])) }
        transcriptChinese = Dictionary(uniqueKeysWithValues: transcriptIndex.map { ($0.cue.id, $0.chinese) })
        updateTranscriptMatches()
    }

    private func subtitleTrackChanged(_ language: SubtitleLanguage) {
        let cues = language == .english ? englishCues : chineseCues
        activeTrackKeys[language] = nil
        if language == .english {
            sentenceBoundaries = [:]
            positionedListeningMark = nil
        }
        if let video = currentSourceVideoURL, !cues.isEmpty {
            let identity = currentVideoRecord?.id.uuidString ?? SubtitleCalibration.storageKey(for: video)
            let track = language == .english ? selectedEnglishEmbeddedTrackID : selectedChineseEmbeddedTrackID
            let key = SubtitleTrackPreferences.key(videoIdentity: "\(identity).\(track ?? -1)", language: language, cues: cues)
            activeTrackKeys[language] = key
            var settings = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SubtitleTrackPreferences.self, from: $0) }
            let claim = "subtitleTrack.legacyClaim.\(identity).\(language)"
            if settings == nil {
                let inherited = defaults.bool(forKey: claim) ? SubtitleTrackTiming() : calibration.timing(for: language)
                settings = SubtitleTrackPreferences(timing: inherited)
                if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
            }
            defaults.set(true, forKey: claim)
            if let settings {
                if language == .english { sentenceBoundaries = settings.boundaries }
                if calibration.timing(for: language) != settings.timing { calibration.apply(settings.timing, for: language) }
            }
        }
        if language == .english { readingTimeline = SubtitleReadingTimeline(cues: cues, boundaries: sentenceBoundaries) }
        rebuildBilingualAlignment()
    }

    private func saveTrackPreferences(_ language: SubtitleLanguage) {
        guard let key = activeTrackKeys[language] else { return }
        let settings = SubtitleTrackPreferences(timing: calibration.timing(for: language),
            boundaries: language == .english ? sentenceBoundaries : [:])
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }

    var sentenceBoundaryEdits: [SentenceBoundaryEdit] {
        let time = sourceTime(playerController.confirmedMilliseconds, for: .english)
        guard let group = listeningPractice?.context ?? readingTimeline.frame(at: time)?.context,
              let last = group.cues.last else { return [] }
        var edits = group.cues.dropFirst().map { SentenceBoundaryEdit(cue: $0, decision: .split) }
        let cues = englishTimeline.allCues
        if group.cues.count < 6, let index = cues.firstIndex(where: { $0.id == last.id }),
           index + 1 < cues.count {
            let next = cues[index + 1]
            if (0...8_000).contains(next.startMilliseconds - last.endMilliseconds) {
                edits.append(SentenceBoundaryEdit(cue: next, decision: .join))
            }
        }
        return edits
    }

    var hasSentenceBoundaryOverrides: Bool { !sentenceBoundaries.isEmpty }

    func applySentenceBoundaryEdit(_ edit: SentenceBoundaryEdit) {
        guard canUseSubtitleAtPlaybackPosition, sentenceBoundaryEdits.contains(where: {
            $0.id == edit.id && $0.decision == edit.decision
        }) else { return }
        let cues = englishTimeline.allCues
        guard let index = cues.firstIndex(where: { $0.id == edit.id }), index > 0 else { return }
        sentenceBoundaries[SubtitleSentenceContext.boundaryKey(cues[index - 1], cues[index])] = edit.decision
        refreshSentenceBoundaries()
    }

    func resetSentenceBoundaries() {
        sentenceBoundaries = [:]
        refreshSentenceBoundaries()
    }

    private func refreshSentenceBoundaries() {
        pauseForLearning()
        setListeningFirst(false)
        stopSentenceLoop()
        readingTimeline = SubtitleReadingTimeline(cues: englishCues, boundaries: sentenceBoundaries)
        rebuildBilingualAlignment()
        saveTrackPreferences(.english)
        objectWillChange.send()
    }

    var displayedSelectedWord: SubtitleWord? {
        guard let request = selectedWordRequest, hasAssistantWord else { return nil }
        guard let frame = readingFrame else {
            return wordSourceCueID == activeEnglish.first?.id && request.sentence == activeEnglishText ? request.word : nil
        }
        guard let segment = frame.segments.first(where: { $0.cue.id == wordSourceCueID }) else { return nil }
        let mapped = SubtitleWord(text: request.word.text, range: NSRange(location: segment.range.location + request.word.range.location, length: request.word.range.length))
        return SubtitleWordTokenizer.isValidTarget(mapped, in: frame.text) ? mapped : nil
    }

    private var playbackUnitCues: [SubtitleCue] { readingFrame?.context.cues ?? activeEnglish }

    func listeningMarkReference() -> (reference: AssistantQuestionReference, time: Int64)? {
        guard canNavigateSubtitles, canUseSubtitleAtPlaybackPosition else { return nil }
        let time = sourceTime(playerController.confirmedMilliseconds, for: .english)
        var cues = listeningPractice?.context.cues ?? playbackUnitCues
        if cues.isEmpty, let previous = englishTimeline.previousCue(at: time),
           (0...1_500).contains(time - previous.endMilliseconds) {
            cues = usesSentenceReading ? readingTimeline.frame(at: previous.startMilliseconds)?.context.cues ?? [previous] : [previous]
        }
        guard let first = cues.first, let reference = questionReference(for: SubtitleSentenceContext(cues: cues)) else { return nil }
        return (reference, videoTime(for: first))
    }

    func setEnglishReadingMode(_ mode: EnglishReadingMode) {
        guard mode != englishReadingMode else { return }
        stopSentenceLoop()
        if !isListeningFirst { clearPlaybackPass() }
        englishReadingMode = mode
        defaults.set(mode.rawValue, forKey: Keys.englishReadingMode)
    }

    var canNavigateSubtitles: Bool {
        !isPreparingMedia && !englishCues.isEmpty && playerController.currentURL != nil
    }

    var canLoopCurrentSentence: Bool {
        canUseSubtitleAtPlaybackPosition && !playbackUnitCues.isEmpty && playerController.currentURL != nil
    }

    var canAnalyzeCurrentSubtitle: Bool {
        canUseSubtitleAtPlaybackPosition && !playbackUnitCues.isEmpty
    }

    var canUseSubtitleAtPlaybackPosition: Bool {
        !isPreparingMedia && (playerController.pendingSeekMilliseconds == nil || hasFinishedListeningPass || pendingListeningMark != nil)
    }

    var isSentenceLoopEnabled: Bool {
        sentenceLoop != nil
    }

    var showEnglishSubtitle: Bool { !isListeningFirst || revealStage.rawValue >= SubtitleRevealStage.english.rawValue }
    var showChineseSubtitle: Bool { !isListeningFirst || revealStage == .bilingual }
    var canStartListeningFirst: Bool {
        canNavigateSubtitles && canUseSubtitleAtPlaybackPosition
            && practice(at: listeningPractice?.startMilliseconds ?? playerController.confirmedMilliseconds) != nil
    }
    var canAdvanceListeningStage: Bool { isListeningFirst && listeningPractice != nil }
    private var hasPracticeChinese: Bool {
        guard let practice = listeningPractice else { return false }
        return !bilingualAlignment.text(for: practice.context).isEmpty
    }
    var listeningStatusTitle: String {
        let state = hasFinishedListeningPass ? "已播完" : (playerController.isPlaying || playerController.isStarting ? "播放中" : "已暂停")
        return "\(revealStage.stageTitle) · \(state)"
    }
    var revealButtonTitle: String {
        switch revealStage {
        case .hidden: "英文重播"
        case .english: hasPracticeChinese ? "双语重播" : "重新盲听"
        case .bilingual: "重新盲听"
        }
    }

    func setListeningFirst(_ enabled: Bool) {
        guard enabled != isListeningFirst else {
            if !enabled { clearPlaybackPass() }
            return
        }
        let nextPractice: ListeningPractice?
        if enabled {
            guard canStartListeningFirst else { return }
            nextPractice = practice(at: listeningPractice?.startMilliseconds ?? playerController.confirmedMilliseconds)
        } else {
            nextPractice = nil
        }
        stopSentenceLoop()
        clearPlaybackPass()
        revealStage = .hidden
        isListeningFirst = nextPractice != nil
        listeningPractice = nextPractice
        if isListeningFirst { replayListeningPass() }
    }

    func revealSubtitle() {
        guard canAdvanceListeningStage else { return }
        revealStage = revealStage == .bilingual || (revealStage == .english && !hasPracticeChinese)
            ? .hidden : revealStage.next
        replayListeningPass()
    }

    private func practice(at videoMilliseconds: Int64) -> ListeningPractice? {
        let time = sourceTime(videoMilliseconds, for: .english)
        let context: SubtitleSentenceContext?
        if let frame = readingTimeline.frame(at: time) { context = frame.context }
        else if let cue = englishTimeline.activeCues(at: time).first {
            // Overlapping speakers are ambiguous. Lock one raw cue, never merge them.
            context = SubtitleSentenceContext(cues: [cue])
        } else if let next = readingTimeline.next(at: time) {
            context = readingTimeline.frame(at: next.startMilliseconds)?.context
        } else { context = nil }
        guard let context else { return nil }
        return ListeningPractice(context: context, timing: calibration.timing(for: .english),
                                 duration: playerController.durationMilliseconds)
    }

    private func replayListeningPass(onStarted: ((PlaybackSpeed) -> Void)? = nil) {
        guard let practice = listeningPractice else { return }
        cancelListeningBoundary()
        replayStarted = onStarted
        // Cancel a queued continuous-loop restart without turning that option off.
        sentenceLoopRestartTask?.cancel()
        sentenceLoopRestartTask = nil
        isRestartingSentenceLoop = false
        hasFinishedListeningPass = false
        playerController.seek(toMilliseconds: practice.startMilliseconds)
        playerController.play()
    }

    private func cancelListeningBoundary() {
        replayStarted = nil
        listeningPlaybackGeneration = UUID()
        listeningBoundaryTask?.cancel()
        listeningBoundaryTask = nil
    }

    private func moveListeningPractice(to cue: SubtitleCue, autoplay: Bool) {
        guard let practice = practice(at: videoTime(for: cue)) else { return }
        stopSentenceLoop()
        cancelListeningBoundary()
        listeningPractice = practice
        revealStage = .hidden
        hasFinishedListeningPass = false
        if autoplay { replayListeningPass() }
        else { playerController.seek(toMilliseconds: practice.startMilliseconds) }
    }

    func subtitleOffset(for language: SubtitleLanguage) -> Int64 { calibration.offset(for: language) }

    func subtitleTiming(for language: SubtitleLanguage) -> SubtitleTrackTiming { calibration.timing(for: language) }
    func subtitleAnchor(for language: SubtitleLanguage) -> SubtitleTimingAnchor? {
        guard canUseSubtitleAtPlaybackPosition,
              let cue = (language == .english ? activeEnglish : activeChinese).first else { return nil }
        return SubtitleTimingAnchor(source: cue.startMilliseconds, video: playerController.confirmedMilliseconds)
    }

    private func sourceTime(_ video: Int64, for language: SubtitleLanguage) -> Int64 {
        calibration.timing(for: language).sourceTime(video)
    }

    private func calibratedVideoTime(_ source: Int64, for language: SubtitleLanguage) -> Int64 {
        calibration.timing(for: language).videoTime(source)
    }

    func setSubtitleOffset(_ milliseconds: Int64, for language: SubtitleLanguage) {
        var timing = calibration.timing(for: language)
        timing.offset = max(-SubtitleCalibration.limit, min(SubtitleCalibration.limit, milliseconds))
        applySubtitleTiming(timing, for: language)
    }

    func applySubtitleTiming(_ timing: SubtitleTrackTiming, for language: SubtitleLanguage) {
        guard timing.isValid else { return }
        stopSentenceLoop()
        let previousPractice = listeningPractice
        let wasPlaying = playerController.isPlaying || playerController.isStarting
        calibration.apply(timing, for: language)
        if language == .english, let previousPractice {
            cancelListeningBoundary()
            listeningPractice = ListeningPractice(context: previousPractice.context,
                timing: calibration.timing(for: .english), duration: playerController.durationMilliseconds)
            revealStage = .hidden
            hasFinishedListeningPass = false
            if let practice = listeningPractice {
                playerController.seek(toMilliseconds: practice.startMilliseconds)
                if wasPlaying { playerController.play() }
            } else { setListeningFirst(false); playerController.pause() }
        }
        if isListeningFirst, revealStage == .bilingual, !hasPracticeChinese { revealStage = .english }
        saveTrackPreferences(language)
        updateActiveSubtitles(at: playerController.confirmedMilliseconds)
    }

    func videoTime(for cue: SubtitleCue) -> Int64 { max(0, calibratedVideoTime(cue.startMilliseconds, for: .english)) }

    func chineseText(for cue: SubtitleCue) -> String {
        transcriptChinese[cue.id] ?? chineseText(for: [cue])
    }

    private func updateTranscriptMatches() {
        let query = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = transcriptIndex.filter {
            query.isEmpty || $0.cue.text.localizedCaseInsensitiveContains(query) || $0.chinese.localizedCaseInsensitiveContains(query)
        }.map(\.cue)
        if result != filteredTranscript { filteredTranscript = result }
    }


    func selectTranscriptCue(_ cue: SubtitleCue) {
        guard englishCues.contains(where: { $0.id == cue.id }) else { return }
        if showEnglishSubtitle { selectQuestionReference(for: sentenceContext(for: cue)) }
        playerController.pause()
        seekPlayback(toMilliseconds: videoTime(for: cue))
    }



    func canStep(by offset: Int) -> Bool {
        destination(by: offset) != nil
    }

    func step(by offset: Int) {
        guard let cue = destination(by: offset) else { return }
        if isListeningFirst {
            moveListeningPractice(to: cue, autoplay: true)
        } else if let pass = playbackPass(for: cue) {
            selectQuestionReference(for: sentenceContext(for: cue))
            playOnce(pass)
        }
    }

    var canReplaySentence: Bool {
        listeningPractice != nil || canLoopCurrentSentence
    }

    var willPlayVideo: Bool {
        isPreparingMedia ? autoplayAfterLoad : playerController.isPlaying || playerController.isStarting
    }

    func openDroppedVideoFile(_ url: URL) { _ = openDroppedVideo([url]) }

    func replaySentence(onStarted: ((ListeningTarget, PlaybackSpeed) -> Void)? = nil) {
        if let practice = listeningPractice, isListeningFirst {
            stopSentenceLoop()
            replayListeningPass(onStarted: replayConfirmation(for: practice, onStarted))
            return
        }
        guard canUseSubtitleAtPlaybackPosition,
              let pass = listeningPractice ?? playbackPass(for: playbackUnitCues.first) else { return }
        playOnce(pass, onStarted: replayConfirmation(for: pass, onStarted))
    }

    private func replayConfirmation(for pass: ListeningPractice, _ onStarted: ((ListeningTarget, PlaybackSpeed) -> Void)?)
        -> ((PlaybackSpeed) -> Void)? {
        guard let onStarted, let reference = questionReference(for: pass.context) else { return nil }
        let target = ListeningTarget(reference: reference, milliseconds: pass.startMilliseconds)
        return { onStarted(target, $0) }
    }

    private func destination(by offset: Int) -> SubtitleCue? {
        guard canNavigateSubtitles,
              playerController.pendingSeekMilliseconds == nil || listeningPractice != nil else { return nil }
        let time = listeningPractice?.context.cues.first?.startMilliseconds
            ?? sourceTime(playerController.confirmedMilliseconds, for: .english)
        if usesSentenceReading {
            return offset < 0 ? readingTimeline.previous(at: time) : readingTimeline.next(at: time)
        }
        return offset < 0 ? englishTimeline.previousCue(at: time) : englishTimeline.nextCue(at: time)
    }

    private func playbackPass(for cue: SubtitleCue?) -> ListeningPractice? {
        guard let cue else { return nil }
        let context = usesSentenceReading
            ? readingTimeline.frame(at: cue.startMilliseconds)?.context ?? SubtitleSentenceContext(cues: [cue])
            : SubtitleSentenceContext(cues: [cue])
        return ListeningPractice(context: context, timing: calibration.timing(for: .english),
                                 duration: playerController.durationMilliseconds)
    }

    private func playOnce(_ pass: ListeningPractice, onStarted: ((PlaybackSpeed) -> Void)? = nil) {
        positionedListeningMark = nil
        stopSentenceLoop()
        listeningPractice = pass
        replayListeningPass(onStarted: onStarted)
    }

    private func clearPlaybackPass() {
        cancelListeningBoundary()
        listeningPractice = nil
        hasFinishedListeningPass = false
    }

    func pauseForModeSwitch() {
        autoplayAfterLoad = false
        pauseForLearning()
        saveCurrentVideoState()
    }

    func skipPlayback(milliseconds: Int64) {
        seekPlayback(toMilliseconds: playerController.currentMilliseconds + milliseconds)
    }

    func togglePlayback() {
        positionedListeningMark = nil
        // Space may arrive before the asynchronous loader has submitted play.
        // Remember that intent instead of having auto-play override the pause.
        if isPreparingMedia {
            autoplayAfterLoad.toggle()
            if !autoplayAfterLoad { playerController.pause() }
            mediaPreparationMessage = autoplayAfterLoad ? "正在打开视频…" : "正在打开视频，完成后保持暂停…"
            return
        }
        if isListeningFirst {
            if hasFinishedListeningPass {
                replayListeningPass()
                return
            }
        } else {
            stopSentenceLoop()
            clearPlaybackPass()
        }
        playerController.togglePlayback()
    }

    func seekPlayback(toMilliseconds milliseconds: Int64) {
        positionedListeningMark = nil
        stopSentenceLoop()
        if isListeningFirst {
            let autoplay = playerController.isPlaying || playerController.isStarting
            if let practice = practice(at: max(0, milliseconds)) {
                cancelListeningBoundary()
                listeningPractice = practice
                revealStage = .hidden
                hasFinishedListeningPass = false
                // Explicit seeking stays exact inside the newly locked sentence.
                // A gap starts at the next sentence rather than running freely.
                let target = max(practice.startMilliseconds, min(milliseconds, practice.endMilliseconds - 1))
                playerController.seek(toMilliseconds: target)
                if autoplay { playerController.play() }
                return
            }
            setListeningFirst(false)
        } else {
            clearPlaybackPass()
        }
        playerController.seek(toMilliseconds: milliseconds)
    }

    func toggleSentenceLoop() {
        if sentenceLoop != nil {
            stopSentenceLoop()
            return
        }
        guard canUseSubtitleAtPlaybackPosition else { return }

        let cues = playbackUnitCues
        guard !cues.isEmpty,
              let start = cues.map(\.startMilliseconds).min(),
              let end = cues.map(\.endMilliseconds).max(),
              end > start else {
            subtitleNotice = "当前时间没有英文字幕，无法开启单句循环。"
            return
        }

        let videoStart = listeningPractice?.startMilliseconds ?? max(0, calibratedVideoTime(start, for: .english))
        let videoEnd = listeningPractice?.endMilliseconds ?? max(videoStart + 1, calibratedVideoTime(end, for: .english))
        sentenceLoop = SentenceLoop(
            startMilliseconds: videoStart,
            endMilliseconds: videoEnd,
            english: cues.map(\.text).joined(separator: readingFrame == nil ? "\n" : " ")
        )
        if listeningPractice != nil {
            replayListeningPass()
            return
        }
        isRestartingSentenceLoop = false
        playerController.seek(toMilliseconds: videoStart)
        playerController.play()
    }

    func stopSentenceLoop() {
        sentenceLoopRestartTask?.cancel()
        sentenceLoopRestartTask = nil
        isRestartingSentenceLoop = false
        sentenceLoop = nil
    }

    /// Queries pause the current pass; they never change its sentence or stage.
    func pauseForLearning() {
        cancelListeningBoundary()
        sentenceLoopRestartTask?.cancel()
        sentenceLoopRestartTask = nil
        isRestartingSentenceLoop = false
        playerController.pause()
        if let practice = listeningPractice,
           playerController.currentMilliseconds >= practice.endMilliseconds {
            // A query can arrive between the clock event and its deferred
            // boundary action. Space must still replay, not resume past the end.
            hasFinishedListeningPass = true
            playerController.seek(toMilliseconds: practice.endMilliseconds - 1)
        }
    }

    func openVideo(_ url: URL, seekTo milliseconds: Int64? = nil) {
        beginLoadingVideo(
            sourceURL: url,
            seekTo: milliseconds
        )
    }

    func openDroppedVideo(_ urls: [URL]) -> Bool {
        guard let video = urls.first(where: VideoFile.isSupported) else {
            alertMessage = "请拖入 MP4、MOV、M4V 或 MKV 视频文件。"
            return false
        }
        openVideo(video)
        return true
    }

    func continueVideo(_ record: VideoLearningRecord) {
        guard record.sourceExists else {
            alertMessage = "视频源文件不存在：\(record.path)"
            refreshRecentVideos()
            return
        }
        beginLoadingVideo(
            sourceURL: record.url,
            seekTo: nil
        )
    }

    func relinkVideo(_ record: VideoLearningRecord, to url: URL) {
        guard let repository else { return }
        do {
            try repository.relinkVideo(record, to: url)
            // Track preferences use the stable record ID. A legacy, unmigrated
            // path-based calibration follows the record without deleting the old key.
            if let legacy = defaults.data(forKey: SubtitleCalibration.storageKey(for: record.url)) {
                let key = SubtitleCalibration.storageKey(for: url)
                if defaults.object(forKey: key) == nil { defaults.set(legacy, forKey: key) }
            }
            refreshRecentVideos()
            beginLoadingVideo(sourceURL: url, seekTo: nil)
        } catch { alertMessage = error.localizedDescription }
    }






    func closeVideo() {
        setListeningFirst(false)
        saveCurrentVideoState()
        mediaLoadTask?.cancel()
        analysisTask?.cancel()
        resetWordLookup()
        englishSubtitleTask?.cancel()
        chineseSubtitleTask?.cancel()
        stopSentenceLoop()
        questionSelection = nil
        currentSourceVideoURL = nil
        currentVideoRecord = nil
        pendingAudioTrackID = nil
        watchAccountingStartedAt = nil
        totalWatchedMilliseconds = 0
        playerController.close()
        clearSubtitles()
        selectedSubtitle = nil
        analysisState = .idle
        sentenceActivityDraft = nil
        sentenceNoteState = .idle
        confirmedSentenceHandle = nil

        isPreparingMedia = false
        mediaPreparationMessage = ""
        refreshRecentVideos()
        calibration = SubtitleCalibration()
        transcriptSearch = ""
        revealStage = .hidden
    }

    func prepareForTermination() {
        saveCurrentVideoState()
        analysisTask?.cancel()
        wordLookupTask?.cancel()
        if case .loading = analysisState { analysisState = .failed("查询已中断，请重试。") }
        if case .loading = wordLookupState { wordLookupState = .failed("查询已中断，请重试。") }
        synchronizeDailyNotes(reportWhenDisabled: false)
    }

    func loadSubtitle(_ url: URL, language: SubtitleLanguage) {
        invalidateSubtitleSelection(language)
        stopSentenceLoop()
        do {
            let result = try SRTParser.parse(data: Data(contentsOf: url))
            switch language {
            case .english:
                selectedEnglishEmbeddedTrackID = nil
                englishSubtitleKind = .external
                englishExternalSubtitleURL = url.standardizedFileURL
                englishCues = result.cues
                englishTimeline = SubtitleTimeline(cues: result.cues)
            case .chinese:
                selectedChineseEmbeddedTrackID = nil
                chineseSubtitleKind = .external
                chineseExternalSubtitleURL = url.standardizedFileURL
                chineseCues = result.cues
                chineseTimeline = SubtitleTimeline(cues: result.cues)
            }
            updateActiveSubtitles(at: playerController.confirmedMilliseconds)
            subtitleNotice = result.skippedBlockCount > 0
                ? "已跳过 \(result.skippedBlockCount) 条无法解析的字幕。"
                : nil
            saveCurrentVideoState()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func loadEmbeddedSubtitle(
        _ track: EmbeddedSubtitleTrack,
        language: SubtitleLanguage
    ) {
        invalidateSubtitleSelection(language)
        stopSentenceLoop()
        guard let sourceURL = currentSourceVideoURL else { return }
        let expectedSource = sourceURL.standardizedFileURL
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await applyEmbeddedSubtitle(
                    track,
                    language: language,
                    sourceURL: expectedSource
                )
            } catch is CancellationError {
                return
            } catch {
                guard currentSourceVideoURL?.standardizedFileURL == expectedSource else {
                    return
                }
                alertMessage = error.localizedDescription
            }
        }

        switch language {
        case .english:
            englishSubtitleTask?.cancel()
            englishSubtitleTask = task
        case .chinese:
            chineseSubtitleTask?.cancel()
            chineseSubtitleTask = task
        }
    }

    func clearSubtitle(language: SubtitleLanguage) {
        invalidateSubtitleSelection(language)
        stopSentenceLoop()
        switch language {
        case .english:
            englishSubtitleTask?.cancel()
            englishCues = []
            activeEnglish = []
            englishTimeline = SubtitleTimeline(cues: [])
            selectedEnglishEmbeddedTrackID = nil
            englishSubtitleKind = .none
            englishExternalSubtitleURL = nil
        case .chinese:
            chineseSubtitleTask?.cancel()
            chineseCues = []
            activeChinese = []
            chineseTimeline = SubtitleTimeline(cues: [])
            selectedChineseEmbeddedTrackID = nil
            chineseSubtitleKind = .none
            chineseExternalSubtitleURL = nil
            if isListeningFirst, revealStage == .bilingual { revealStage = .english }
        }
        updateActiveSubtitles(at: playerController.confirmedMilliseconds)
        saveCurrentVideoState()
    }

    func analyzeCurrentSubtitle() {
        selectCurrentSubtitle(analyze: true)
    }

    func translateCurrentSubtitle() {
        guard showEnglishSubtitle else { return }
        selectCurrentSubtitle(analyze: false)
    }

    private func selectCurrentSubtitle(analyze: Bool) {
        guard canAnalyzeCurrentSubtitle else { return }
        let frame = readingFrame
        let context = frame?.context ?? SubtitleSentenceContext.build(
            in: englishTimeline.allCues, selected: activeEnglish, boundaries: sentenceBoundaries)
        let cues = frame?.context.cues ?? (analyze ? activeEnglish : context?.cues ?? activeEnglish)
        analyzeSubtitle(cues: cues, english: analyze ? frame?.text ?? activeEnglishText : context?.english ?? displayedEnglishText,
                        chinese: chineseText(for: cues), sourceContext: context, analyze: analyze)
    }

    var hasAssistantWord: Bool {
        guard let draft = wordActivityDraft else { return false }
        return draft.videoURL == currentSourceVideoURL && draft.englishTrackKey == activeTrackKeys[.english]
    }

    private func analyzeSubtitle(cues: [SubtitleCue], english: String, chinese: String,
                                 sourceContext: SubtitleSentenceContext?, analyze: Bool = true, keepWord: Bool = false) {
        if !keepWord { pauseForLearning() }
        let context = englishTimeline.context(around: cues)
        let selection = SubtitleSelection(
            english: english,
            chinese: chinese,
            startMilliseconds: max(0, calibratedVideoTime(cues.map(\.startMilliseconds).min() ?? 0, for: .english)),
            endMilliseconds: max(0, calibratedVideoTime(cues.map(\.endMilliseconds).max() ?? 0, for: .english)),
            previousEnglish: context.previous,
            nextEnglish: context.next,
            videoURL: currentSourceVideoURL,
            sourceContext: sourceContext,
            rawStartMilliseconds: cues.map(\.startMilliseconds).min(),
            englishTiming: calibration.timing(for: .english), chineseTiming: calibration.timing(for: .chinese),
            englishTrackKey: activeTrackKeys[.english]
        )

        if !keepWord {
            sidebarMode = .analysis
            if showEnglishSubtitle { selectQuestionReference(for: sourceContext ?? SubtitleSentenceContext(cues: cues)) }
        }
        if selection != selectedSubtitle {
            analysisTask?.cancel()
            analysisRequestID = UUID()
            analysisState = .idle
            sentenceActivityDraft = nil
            sentenceNoteState = .idle
            confirmedSentenceHandle = nil
            selectedSubtitle = selection
        }
        assistantGrammarExpanded = analyze
        if analyze, analysisState != .loading || activeSentenceModelID != selectedModelID {
            requestAnalysis(for: selection)
        }
    }

    func toggleAssistantGrammar() {
        guard let selection = selectedSubtitle else { return }
        assistantGrammarExpanded.toggle()
        if assistantGrammarExpanded, analysisState == .idle {
            pauseForLearning()
            requestAnalysis(for: selection)
        }
    }

    var assistantPhraseRequest: StudyRequest? {
        guard hasAssistantWord, let request = selectedWordRequest else { return nil }
        let sentenceText = request.sourceContext?.english ?? request.sentence
        let sentence = TextExcerpt(text: sentenceText, range: NSRange(location: 0, length: sentenceText.utf16.count), context: sentenceText)
        let preceding = request.sourceContext?.cues.prefix { $0.id != wordSourceCueID }
        let offset = preceding?.reduce(0) { $0 + $1.text.utf16.count + 1 } ?? 0
        let target = SubtitleWord(text: request.word.text,
                                  range: NSRange(location: offset + request.word.range.location,
                                                 length: request.word.range.length))
        guard let word = sentence.focus(on: target) else { return nil }
        let context = request.sourceContext.map { englishTimeline.context(around: $0.cues) }
        return StudyRequest(kind: .phrase, target: sentence, focusedWord: word,
                            sources: [StudySource(id: "S1", excerpt: sentence)],
                            surrounding: SentenceContext(previousSentence: context?.previous ?? request.previousEnglish,
                                                         nextSentence: context?.next ?? request.nextEnglish))
    }

    func retryAnalysis() {
        guard let selectedSubtitle else { return }
        requestAnalysis(for: selectedSubtitle)
    }

    func cancelAnalysis() {
        guard case .loading = analysisState else { return }
        analysisRequestID = UUID()
        analysisTask?.cancel()
        analysisState = .failed("已取消整句解析，可重试。")
    }

    func cancelWordLookup() {
        guard case .loading = wordLookupState else { return }
        wordLookupID = UUID()
        wordLookupTask?.cancel()
        wordLookupState = .failed("已取消查词，可重试。")
    }

    private var usesWordSource: Bool { sidebarMode == .word || sidebarMode == .phrase }

    var sidebarSource: (sentence: String, time: Int64)? {
        if usesWordSource {
            guard let draft = wordActivityDraft, hasAssistantWord else { return nil }
            let rawStart = draft.sourceContext?.cues.first?.startMilliseconds ?? draft.sourceStartMilliseconds
            let time = rawStart.map { max(0, calibratedVideoTime($0, for: .english)) } ?? draft.startMilliseconds
            return (draft.sourceContext?.english ?? draft.english, time)
        }
        guard let selection = selectedSubtitle, selection.videoURL == currentSourceVideoURL,
              selection.englishTrackKey == activeTrackKeys[.english] else { return nil }
        let time = selection.rawStartMilliseconds.map { max(0, calibratedVideoTime($0, for: .english)) }
            ?? selection.startMilliseconds
        return (selection.english, time)
    }

    func questionReference(currentOnly: Bool) -> AssistantQuestionReference? {
        guard showEnglishSubtitle else { return nil }
        if !currentOnly, let source = sidebarSource, sidebarMode != .transcript {
            if usesWordSource, let request = selectedWordRequest {
                if let context = request.sourceContext { return questionReference(for: context, focus: request.word.text) }
                return AssistantQuestionReference(passage: source.sentence, focus: request.word.text,
                    timestamp: SubtitleTimeLabel.string(source.time),
                    surrounding: SentenceContext(previousSentence: request.previousEnglish, nextSentence: request.nextEnglish))
            }
            if let selection = selectedSubtitle {
                if let context = selection.sourceContext { return questionReference(for: context) }
                return AssistantQuestionReference(passage: source.sentence, timestamp: SubtitleTimeLabel.string(source.time),
                    surrounding: SentenceContext(previousSentence: selection.previousEnglish, nextSentence: selection.nextEnglish))
            }
        }
        guard canUseSubtitleAtPlaybackPosition,
              let context = readingFrame?.context ?? SubtitleSentenceContext.build(
                in: englishTimeline.allCues, selected: activeEnglish, boundaries: sentenceBoundaries
              ) else { return nil }
        return questionReference(for: context)
    }

    private func sentenceContext(for cue: SubtitleCue) -> SubtitleSentenceContext {
        SubtitleSentenceContext.build(in: englishTimeline.allCues, selected: [cue], boundaries: sentenceBoundaries)
            ?? SubtitleSentenceContext(cues: [cue])
    }

    private func questionReference(for context: SubtitleSentenceContext, focus: String? = nil) -> AssistantQuestionReference? {
        guard let first = context.cues.first else { return nil }
        let neighbours = englishTimeline.context(around: context.cues)
        let time = max(0, calibratedVideoTime(first.startMilliseconds, for: .english))
        let source = currentSourceVideoURL.map { url in
            AssistantQuestionSource(title: url.lastPathComponent, location: .video(file: url,
                cues: context.cues.map { .init(start: $0.startMilliseconds, text: $0.text) }), videoTrack: currentEnglishTrack)
        }
        return AssistantQuestionReference(passage: context.english, focus: focus, timestamp: SubtitleTimeLabel.string(time),
            surrounding: SentenceContext(previousSentence: neighbours.previous, nextSentence: neighbours.next), source: source)
    }

    private typealias VideoTrack = AssistantQuestionSource.VideoTrack

    private struct ReferenceTrack {
        let identity: VideoTrack
        let cues: [SubtitleCue]
    }

    var currentEnglishTrack: AssistantQuestionSource.VideoTrack? {
        if let url = englishExternalSubtitleURL { return .external(url) }
        return selectedEnglishEmbeddedTrackID.map(VideoTrack.embedded)
    }

    // Older favorites carry only the file and cue anchors. Use the film's saved track
    // in that case, and still require an exact match before changing playback.
    private func referenceTrack(_ identity: VideoTrack?, for url: URL) async throws -> ReferenceTrack {
        var track = identity
        if track == nil, let saved = try repository?.videoRecord(for: url) {
            if saved.englishSubtitleKind == .external, let path = saved.englishSubtitlePath {
                track = .external(URL(fileURLWithPath: path))
            } else if let id = saved.englishSubtitleTrackID { track = .embedded(id) }
        }
        if case .external(let file) = track {
            let cues = try await Task.detached {
                try SRTParser.parse(data: Data(contentsOf: file)).cues
            }.value
            return ReferenceTrack(identity: .external(file), cues: cues)
        }
        let tracks = try await embeddedSubtitleService.discoverTracks(in: url).filter(\.isTextBased)
        let embedded: EmbeddedSubtitleTrack?
        if case .embedded(let id) = track { embedded = tracks.first { $0.id == id } }
        else { embedded = preferredTrack(in: tracks, languageCodes: ["en", "eng"]) ?? (tracks.count == 1 ? tracks.first : nil) }
        guard let embedded else { throw ReaderError.message("找不到原来的英文字幕轨。") }
        let data = try await embeddedSubtitleService.extract(track: embedded, from: url)
        return ReferenceTrack(identity: .embedded(embedded.id), cues: try SRTParser.parse(data: data).cues)
    }

    private func useReferenceTrack(_ track: ReferenceTrack) {
        invalidateSubtitleSelection(.english)
        stopSentenceLoop()
        switch track.identity {
        case .external(let url):
            englishSubtitleKind = .external
            englishExternalSubtitleURL = url
            selectedEnglishEmbeddedTrackID = nil
        case .embedded(let id):
            englishSubtitleKind = .embedded
            englishExternalSubtitleURL = nil
            selectedEnglishEmbeddedTrackID = id
        }
        englishCues = track.cues
        englishTimeline = SubtitleTimeline(cues: track.cues)
        updateActiveSubtitles(at: playerController.confirmedMilliseconds)
    }

    func locateQuestionSource(_ reference: AssistantQuestionReference, excerpt: NSRange?, reviewMark: Bool? = nil,
                              onReplayStarted: ((ListeningTarget, PlaybackSpeed) -> Void)? = nil) async throws {
        guard case let .video(url, anchors)? = reference.source?.location,
              VideoFile.isSupported(url), FileManager.default.isReadableFile(atPath: url.path) else {
            throw ReaderError.message("找不到这条问答的视频文件。")
        }
        let wanted = excerpt?.location ?? 0
        let passage = anchors.map(\.text).joined(separator: " ")
        guard !anchors.isEmpty, passage.utf8.elementsEqual(reference.passage.utf8),
              wanted >= 0, wanted < passage.utf16.count else { throw ReaderError.message("找不到这段原文的位置。") }

        let originalURL = currentSourceVideoURL
        let originalLoad = mediaLoadID
        let originalTrack = englishSubtitleGeneration
        let track = reference.source?.videoTrack
        let prepared: ReferenceTrack?
        if originalURL == url && (track == nil || currentEnglishTrack == track) { prepared = nil }
        else { prepared = try await referenceTrack(track, for: url) }
        try Task.checkCancellation()
        guard originalLoad == mediaLoadID, originalURL == currentSourceVideoURL,
              originalTrack == englishSubtitleGeneration else { throw CancellationError() }
        let cues = prepared?.cues ?? englishCues
        let sourceCues = anchors.compactMap { anchor in
            cues.first { $0.startMilliseconds == anchor.start && $0.text.utf8.elementsEqual(anchor.text.utf8) }
        }
        guard sourceCues.count == anchors.count else { throw ReaderError.message("原字幕内容已改变，无法定位原句。") }

        if originalURL != url {
            let previousPosition = playerController.confirmedMilliseconds
            let wasPlaying = playerController.isPlaying
            beginLoadingVideo(sourceURL: url, seekTo: nil, autoplay: false, referenceTrack: prepared)
            let requestID = mediaLoadID
            await mediaLoadTask?.value
            try Task.checkCancellation()
            guard mediaLoadID == requestID else { throw CancellationError() }
            guard currentSourceVideoURL == url else {
                if let originalURL {
                    beginLoadingVideo(sourceURL: originalURL, seekTo: previousPosition, autoplay: wasPlaying)
                    await mediaLoadTask?.value
                }
                throw ReaderError.message("视频打开失败。")
            }
        } else if let prepared {
            useReferenceTrack(prepared)
            saveCurrentVideoState()
        }
        if let replay = reviewMark, let first = sourceCues.first {
            let context = SubtitleSentenceContext(cues: sourceCues)
            if replay {
                guard let pass = ListeningPractice(context: context, timing: calibration.timing(for: .english),
                                                   duration: playerController.durationMilliseconds) else {
                    throw ReaderError.message("这段字幕已超出视频的可播放范围。")
                }
                playOnce(pass, onStarted: replayConfirmation(for: pass, onReplayStarted))
            } else {
                pauseForLearning()
                seekPlayback(toMilliseconds: videoTime(for: first))
                // VLC may hold a paused seek until playback resumes. Show the
                // explicitly selected source line while its clock catches up.
                positionedListeningMark = context
            }
            if isListeningFirst { revealStage = .english }
            selectQuestionReference(for: context)
            return
        }
        var offset = 0
        for cue in anchors {
            offset += cue.text.utf16.count + 1
            if wanted < offset {
                pauseForLearning()
                seekPlayback(toMilliseconds: max(0, calibratedVideoTime(cue.start, for: .english)))
                return
            }
        }
    }

    private func selectQuestionReference(for context: SubtitleSentenceContext, focus: String? = nil) {
        guard let reference = questionReference(for: context, focus: focus) else { return }
        questionSelection = AssistantQuestionSelection(reference: reference)
    }

    func jumpToSidebarSource() {
        guard let source = sidebarSource else { return }
        pauseForLearning()
        seekPlayback(toMilliseconds: source.time)
    }

    func lookupWord(_ word: SubtitleWord, in sentence: String) {
        // Reject a stale click if playback replaced the visible subtitle.
        guard canUseSubtitleAtPlaybackPosition, sentence == activeEnglishText,
              SubtitleWordTokenizer.isValidTarget(word, in: sentence) else { return }
        beginWordLookup(word, in: sentence, cues: activeEnglish,
            sourceContext: SubtitleSentenceContext.build(in: englishTimeline.allCues, selected: activeEnglish, boundaries: sentenceBoundaries), chinese: activeChineseText)
    }

    func lookupDisplayedWord(_ word: SubtitleWord, in sentence: String) {
        guard canUseSubtitleAtPlaybackPosition else { return }
        guard let frame = readingFrame else { lookupWord(word, in: sentence); return }
        guard sentence == frame.text, let source = frame.source(for: word) else { return }
        beginWordLookup(source.word, in: source.text, cues: source.cues,
            sourceContext: frame.context, chinese: chineseText(for: source.cues))
    }

    private func chineseText(for cues: [SubtitleCue]) -> String {
        bilingualAlignment.cues(forEnglishCues: cues).map(\.text).joined(separator: " ")
    }

    private var wordSourceCueID: UUID?

    private func beginWordLookup(_ word: SubtitleWord, in sentence: String, cues: [SubtitleCue], sourceContext: SubtitleSentenceContext?, chinese: String) {
        pauseForLearning()
        let context = englishTimeline.context(around: cues)
        let request = WordLookupRequest(
            word: word, sentence: sentence, chinese: chinese,
            previousEnglish: context.previous, nextEnglish: context.next,
            sourceContext: sourceContext
        )
        wordSourceCueID = cues.first?.id
        sidebarMode = .word
        if showEnglishSubtitle {
            selectQuestionReference(for: sourceContext ?? SubtitleSentenceContext(cues: cues), focus: word.text)
        }
        wordActivityDraft = (currentSourceVideoURL ?? playerController.currentURL).map {
            LearningActivityDraft(
                kind: .word, videoURL: $0, english: request.sentence, chinese: request.chinese,
                previousEnglish: request.previousEnglish, nextEnglish: request.nextEnglish,
                startMilliseconds: max(0, calibratedVideoTime(cues.map(\.startMilliseconds).min() ?? 0, for: .english)),
                endMilliseconds: max(0, calibratedVideoTime(cues.map(\.endMilliseconds).max() ?? 0, for: .english)),
                word: request.word,
                sourceStartMilliseconds: cues.map(\.startMilliseconds).min(),
                englishOffsetMilliseconds: calibration.englishMilliseconds,
                chineseOffsetMilliseconds: calibration.chineseMilliseconds,
                sourceContext: request.sourceContext,
                englishTrackKey: activeTrackKeys[.english],
                englishTiming: calibration.timing(for: .english),
                chineseTiming: calibration.timing(for: .chinese)
            )
        }
        let sentenceCues = sourceContext?.cues ?? cues
        analyzeSubtitle(cues: sentenceCues, english: sourceContext?.english ?? sentence,
                        chinese: sourceContext == nil ? chinese : chineseText(for: sentenceCues),
                        sourceContext: sourceContext, analyze: false, keepWord: true)
        if selectedWordRequest == request, wordLookupState == .loading, activeWordModelID == selectedModelID { return }
        if selectedWordRequest == request, cachedWordModelID == selectedModelID, case .loaded = wordLookupState {
            return
        }
        selectedWordRequest = request
        requestWordExplanation(for: request)
    }

    func retryWordLookup() {
        guard let selectedWordRequest else { return }
        requestWordExplanation(for: selectedWordRequest)
    }

    private func resetWordLookup() {
        wordLookupTask?.cancel()
        wordLookupID = UUID()
        selectedWordRequest = nil
        wordLookupState = .idle
        wordActivityDraft = nil
        wordSourceCueID = nil
        cachedWordModelID = ""
        wordNoteState = .idle
        confirmedWordHandle = nil
    }

    private func requestWordExplanation(for request: WordLookupRequest) {
        wordLookupTask?.cancel()
        wordNoteState = .idle
        confirmedWordHandle = nil
        let requestID = UUID()
        wordLookupID = requestID
        wordLookupState = .loading
        let settings = modelSettings()
        activeWordModelID = settings.model
        wordLookupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let modelID = try await resolveModel(settings)
                try Task.checkCancellation()
                activeWordModelID = modelID
                let explanation = try await wordLookupService.lookupWord(
                    request: request, baseURL: settings.endpoint, modelID: modelID
                )
                try Task.checkCancellation()
                guard wordLookupID == requestID else { return }
                wordLookupState = .loaded(explanation)
                cachedWordModelID = modelID
            } catch {
                guard !Task.isCancelled, wordLookupID == requestID else { return }
                wordLookupState = .failed(error.localizedDescription)
            }
        }
    }

    private func resolveModel(_ settings: (endpoint: String, model: String)) async throws -> String {
        if !settings.model.isEmpty { return settings.model }
        let models = try await aiService.listModels(baseURL: settings.endpoint)
        guard let model = models.first else { throw AIServiceError.modelSelectionRequired }
        return model
    }

    func setObsidianVault(_ url: URL) {
        var isDirectory: ObjCBool = false
        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue else {
            obsidianSyncStatus = "所选文件夹不存在或无法访问。"
            return
        }
        do { authorizedObsidianDirectory = try ObsidianExportService.verifiedDestination(for: standardizedURL) }
        catch { obsidianSyncStatus = error.localizedDescription; return }
        obsidianVaultPath = standardizedURL.path
        defaults.set(obsidianVaultPath, forKey: Keys.obsidianVaultPath)
        defaults.set(authorizedObsidianDirectory, forKey: Keys.authorizedObsidianDirectory)
        noteMigrationPreview = nil
        synchronizeDailyNotes(reportWhenDisabled: true)
    }

    func clearObsidianVault() {
        noteMigrationPreview = nil
        obsidianVaultPath = ""
        authorizedObsidianDirectory = ""
        obsidianSyncStatus = "已停止写入；现有笔记和此前确认的本地记录不删除。"
        defaults.removeObject(forKey: Keys.obsidianVaultPath)
        defaults.removeObject(forKey: Keys.authorizedObsidianDirectory)
    }

    func synchronizeDailyNotes() {
        synchronizeDailyNotes(reportWhenDisabled: true)
    }

    func previewNoteMigration() {
        guard let repository, !obsidianDestinationPath.isEmpty else { return }
        do {
            let eligible = try repository.fetchActivities().filter { $0.confirmedAt != nil && $0.status == .completed }
            guard !eligible.isEmpty else {
                obsidianSyncStatus = "没有已确认的历史笔记。"
                return
            }
            noteMigrationPreview = NoteMigrationPreview(destination: obsidianDestinationPath, entries: eligible)
        } catch { obsidianSyncStatus = error.localizedDescription }
    }

    func cancelNoteMigration() { noteMigrationPreview = nil }

    func confirmNoteMigration() {
        guard let preview = noteMigrationPreview, let repository else { return }
        noteMigrationPreview = nil
        do {
            let current = try repository.fetchActivities().filter { $0.confirmedAt != nil && $0.status == .completed }
            guard preview.destination == obsidianDestinationPath, current == preview.entries else {
                obsidianSyncStatus = "目录或记录已变化，请重新预览。"
                return
            }
            try repository.queueConfirmedHistory(to: preview.destination)
            synchronizeDailyNotes(reportWhenDisabled: true)
        } catch { obsidianSyncStatus = error.localizedDescription }
    }





    private func beginLoadingVideo(
        sourceURL: URL,
        seekTo milliseconds: Int64?,
        autoplay: Bool = true,
        referenceTrack: ReferenceTrack? = nil
    ) {
        autoplayAfterLoad = autoplay
        saveCurrentVideoState()
        mediaLoadTask?.cancel()
        analysisTask?.cancel()
        resetWordLookup()
        englishSubtitleTask?.cancel()
        chineseSubtitleTask?.cancel()
        setListeningFirst(false)
        stopSentenceLoop()
        playerController.pause()
        questionSelection = nil
        currentSourceVideoURL = nil
        currentVideoRecord = nil
        watchAccountingStartedAt = nil

        let standardizedSource = sourceURL.standardizedFileURL
        transcriptSearch = ""
        let restoredRecord: VideoLearningRecord?
        do {
            restoredRecord = try repository?.videoRecord(for: standardizedSource)
        } catch {
            restoredRecord = nil
            alertMessage = error.localizedDescription
        }
        let isMKV = standardizedSource.pathExtension.lowercased() == "mkv"
        playbackLog.notice("Resume snapshot: \(restoredRecord?.lastPositionMilliseconds ?? -1)")
        let loadID = UUID()
        mediaLoadID = loadID
        isPreparingMedia = true
        mediaPreparationMessage = isMKV ? "正在直接打开 MKV 视频…" : "正在打开视频…"

        mediaLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await playerController.load(url: standardizedSource)

                try Task.checkCancellation()
                guard mediaLoadID == loadID else { return }
                currentSourceVideoURL = standardizedSource
                clearSubtitles()
                selectedSubtitle = nil
                analysisState = .idle

                let registeredRecord: VideoLearningRecord?
                do {
                    registeredRecord = try repository?.registerVideo(
                        url: standardizedSource,
                        displayName: standardizedSource.lastPathComponent,
                        durationMilliseconds: playerController.durationMilliseconds
                    )
                } catch {
                    registeredRecord = restoredRecord
                    alertMessage = error.localizedDescription
                }
                let learningRecord = registeredRecord ?? restoredRecord
                playbackLog.notice("Registered resume position: \(learningRecord?.lastPositionMilliseconds ?? -1)")
                currentVideoRecord = learningRecord
                totalWatchedMilliseconds =
                    learningRecord?.totalWatchedMilliseconds ?? 0
                watchAccountingStartedAt = nil
                pendingAudioTrackID = learningRecord?.selectedAudioTrackID
                restoreSubtitleSelectionState(from: learningRecord)
                calibration = defaults.data(forKey: SubtitleCalibration.storageKey(for: standardizedSource))
                    .flatMap { try? JSONDecoder().decode(SubtitleCalibration.self, from: $0) } ?? SubtitleCalibration()
                // Saved external tracks do not depend on FFmpeg discovery.
                for (language, path) in [(SubtitleLanguage.english, learningRecord?.englishSubtitlePath),
                                         (.chinese, learningRecord?.chineseSubtitlePath)] {
                    if let path, FileManager.default.isReadableFile(atPath: path) {
                        do { try applyExternalSubtitle(URL(fileURLWithPath: path), language: language) }
                        catch { subtitleNotice = "外部字幕读取失败：\(error.localizedDescription)；视频仍可播放。" }
                    }
                }
                if let referenceTrack { useReferenceTrack(referenceTrack) }
                playerController.playbackRate = PlaybackSpeed(savedRate: Float(learningRecord?.playbackRate ?? 1)).rawValue

                isPreparingMedia = false
                mediaPreparationMessage = ""

                let resumePosition = learningRecord.map {
                    max(0, $0.lastPositionMilliseconds - 2_000)
                }
                if let target = milliseconds ?? resumePosition,
                   target > 0 {
                    playbackLog.notice("Applying resume target: \(target)")
                    playerController.seek(toMilliseconds: target)
                }
                if autoplayAfterLoad { playerController.play() }
                else { playerController.pause() }

                await discoverAndLoadEmbeddedSubtitles(
                    from: standardizedSource,
                    loadID: loadID,
                    restoredRecord: learningRecord
                )
                saveCurrentVideoState()
                refreshRecentVideos()
            } catch is CancellationError {
                return
            } catch {
                guard mediaLoadID == loadID else { return }
                alertMessage = error.localizedDescription
            }

            if mediaLoadID == loadID {
                isPreparingMedia = false
                mediaPreparationMessage = ""
            }
        }
    }

    private func requestAnalysis(for selection: SubtitleSelection) {
        analysisTask?.cancel()
        sentenceNoteState = .idle
        confirmedSentenceHandle = nil
        analysisState = .loading
        let requestID = UUID()
        analysisRequestID = requestID
        let settings = modelSettings()
        activeSentenceModelID = settings.model
        sentenceActivityDraft = selection.videoURL.map {
            LearningActivityDraft(
                kind: .sentence, videoURL: $0, english: selection.english, chinese: selection.chinese,
                previousEnglish: selection.previousEnglish, nextEnglish: selection.nextEnglish,
                startMilliseconds: selection.startMilliseconds, endMilliseconds: selection.endMilliseconds,
                sourceStartMilliseconds: selection.rawStartMilliseconds,
                englishOffsetMilliseconds: selection.englishTiming?.offset,
                chineseOffsetMilliseconds: selection.chineseTiming?.offset,
                sourceContext: selection.sourceContext,
                englishTrackKey: selection.englishTrackKey,
                englishTiming: selection.englishTiming,
                chineseTiming: selection.chineseTiming
            )
        }

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let modelID = try await resolveModel(settings)
                try Task.checkCancellation()
                activeSentenceModelID = modelID

                let result = try await aiService.analyze(
                    request: AIAnalysisRequest(
                        english: selection.english,
                        chinese: selection.chinese,
                        previousEnglish: selection.previousEnglish,
                        nextEnglish: selection.nextEnglish,
                        sourceContext: selection.sourceContext
                    ),
                    baseURL: settings.endpoint,
                    modelID: modelID
                )
                try Task.checkCancellation()
                guard selectedSubtitle == selection, analysisRequestID == requestID else { return }
                analysisState = .loaded(result)
                cachedSentenceModelID = modelID
            } catch is CancellationError {
                return
            } catch {
                guard selectedSubtitle == selection, analysisRequestID == requestID else { return }
                guard !Task.isCancelled else { return }
                analysisState = .failed(error.localizedDescription)
            }
        }
    }





    var obsidianDestinationPath: String {
        authorizedObsidianDirectory
    }

    func canConfirmNote(forWord: Bool) -> Bool {
        guard repository != nil, !obsidianDestinationPath.isEmpty else { return false }
        switch forWord ? wordNoteState : sentenceNoteState {
        case .writing, .saved: return false
        case .idle, .pending: break
        }
        if forWord, case .loaded = wordLookupState { return hasAssistantWord }
        if !forWord, case .loaded = analysisState { return sentenceActivityDraft != nil }
        return false
    }

    /// This is the only path from a displayed answer to a learning record.
    /// Capture the answer/source before awaiting IO; playback/tab/query changes
    /// must never make the button save a different sentence or word.
    func confirmNote(forWord isWord: Bool) {
        guard canConfirmNote(forWord: isWord), let repository else { return }
        let queryID = isWord ? wordLookupID : analysisRequestID
        let draft = isWord ? wordActivityDraft : sentenceActivityDraft
        let modelID = isWord ? cachedWordModelID : cachedSentenceModelID
        var handle = isWord ? confirmedWordHandle : confirmedSentenceHandle
        do {
            if handle == nil {
                guard let draft else { return }
                let entry = try repository.recordInteraction(draft, at: activityNow(), timeZone: activityTimeZone, modelID: modelID)
                let finished: Bool
                if isWord, case let .loaded(word) = wordLookupState {
                    finished = try repository.finishInteraction(entry.handle, status: .completed, word: word, modelID: modelID, completedAt: activityNow())
                } else if !isWord, case let .loaded(sentence) = analysisState {
                    finished = try repository.finishInteraction(entry.handle, status: .completed, sentence: sentence, modelID: modelID, completedAt: activityNow())
                } else { return }
                guard finished, try repository.confirmInteraction(entry.handle, at: activityNow(), destination: obsidianDestinationPath) else { return }
                handle = entry.handle
                if isWord { confirmedWordHandle = handle } else { confirmedSentenceHandle = handle }
            }
            guard let handle else { return }
            if isWord { wordNoteState = .writing } else { sentenceNoteState = .writing }
            Task { [weak self] in
                guard let self else { return }
                await waitForNoteSynchronization()
                let stillSelected = isWord ? wordLookupID == queryID : analysisRequestID == queryID
                guard stillSelected else { return }
                let pending = (try? repository.pendingConfirmedActivities().contains { $0.id == handle.id }) ?? true
                let state: NoteConfirmationState = pending
                    ? .pending(obsidianSyncStatus.isEmpty ? "已确认，等待写入；可重试。" : obsidianSyncStatus)
                    : .saved("AEVP-\(handle.dayKey)")
                if isWord { wordNoteState = state } else { sentenceNoteState = state }
            }
        } catch {
            let state = NoteConfirmationState.pending("未能添加：\(error.localizedDescription)")
            if isWord { wordNoteState = state } else { sentenceNoteState = state }
        }
    }

    private func synchronizeDailyNotes(reportWhenDisabled: Bool) {
        guard !obsidianVaultPath.isEmpty else {
            if reportWhenDisabled { obsidianSyncStatus = "请先选择 Obsidian 库或英语学习文件夹；只有手动确认的结果才会写入。" }
            return
        }
        guard let repository else { return }
        guard noteSyncTask == nil else { return }
        let destination = obsidianVaultPath
        let authorizedDirectory = obsidianDestinationPath
        guard !authorizedDirectory.isEmpty else {
            if reportWhenDisabled { obsidianSyncStatus = "无法访问日报目录；已确认记录保留在本机。" }
            return
        }
        noteSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                noteSyncTask = nil
                if destination != obsidianVaultPath, !obsidianVaultPath.isEmpty {
                    synchronizeDailyNotes(reportWhenDisabled: false)
                }
            }
            var exportedIDs: Set<UUID> = []
            do {
                // A completion can arrive while its pending snapshot is being
                // written. Only mark an unchanged snapshot exported; otherwise
                // loop and write the newer generation before clearing its flag.
                while destination == obsidianVaultPath {
                    let queued = try repository.pendingConfirmedActivities()
                    let batches = Dictionary(grouping: queued.filter {
                        ($0.exportDestination ?? self.legacyExportDestination) == authorizedDirectory
                    }, by: \.dayKey)
                    if batches.isEmpty {
                        if !exportedIDs.isEmpty { obsidianSyncStatus = "已同步 \(exportedIDs.count) 条已确认解析；同一天更新同一篇笔记。" }
                        else if reportWhenDisabled { obsidianSyncStatus = queued.isEmpty
                            ? "没有待同步的已确认解析。"
                            : "还有 \(queued.count) 条记录属于其他目录，未写入当前库。" }
                        break
                    }
                    var failures: [String] = []
                    for day in batches.keys.sorted() {
                        guard destination == obsidianVaultPath, authorizedDirectory == obsidianDestinationPath,
                              let snapshot = batches[day] else { return }
                        do {
                            _ = try await noteWriter.write(snapshot, to: URL(fileURLWithPath: destination),
                                                           expectedDirectory: authorizedDirectory)
                            try repository.markExported(snapshot)
                            exportedIDs.formUnion(snapshot.map(\.id))
                        } catch { failures.append("\(day)：\(error.localizedDescription)") }
                    }
                    if !failures.isEmpty {
                        obsidianSyncStatus = "部分记录尚未写入，已保存在本机并会自动重试。\(failures.joined(separator: "；"))"
                        break
                    }
                    await Task.yield()
                }
            } catch { obsidianSyncStatus = "同步失败，记录保留在本机：\(error.localizedDescription)" }
        }
    }

    func waitForNoteSynchronization() async {
        synchronizeDailyNotes(reportWhenDisabled: false)
        while let task = noteSyncTask { await task.value }
    }


    private func refreshRecentVideos() {
        guard let repository else { return }
        do {
            recentVideos = try repository.fetchRecentVideos()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func handlePlayingState(_ isPlaying: Bool) {
        if isPlaying {
            if watchAccountingStartedAt == nil,
               currentSourceVideoURL != nil {
                watchAccountingStartedAt = Date()
            }
            return
        }

        accountForWatchedTime()
        watchAccountingStartedAt = nil
        saveCurrentVideoState()
    }

    private func accountForWatchedTime() {
        guard let watchAccountingStartedAt else { return }
        let elapsed = max(0, Date().timeIntervalSince(watchAccountingStartedAt))
        totalWatchedMilliseconds += Int64((elapsed * 1_000).rounded())
        self.watchAccountingStartedAt = playerController.isPlaying
            ? Date()
            : nil
    }

    private func saveCurrentVideoState() {
        guard let repository,
              let currentSourceVideoURL else {
            return
        }

        accountForWatchedTime()
        let draft = VideoLearningStateDraft(
            videoURL: currentSourceVideoURL,
            displayName: currentSourceVideoURL.lastPathComponent,
            durationMilliseconds: playerController.durationMilliseconds,
            lastPositionMilliseconds: playerController.pendingSeekMilliseconds != nil && playerController.confirmedMilliseconds == 0
                ? (lastSavedVideoState?.videoURL == currentSourceVideoURL ? lastSavedVideoState?.lastPositionMilliseconds : nil)
                    ?? currentVideoRecord?.lastPositionMilliseconds ?? 0
                : playerController.confirmedMilliseconds,
            totalWatchedMilliseconds: totalWatchedMilliseconds,
            playbackRate: Double(playerController.playbackRate),
            selectedAudioTrackID: playerController.selectedAudioTrackID,
            englishSubtitleKind: englishSubtitleKind,
            englishSubtitlePath: englishExternalSubtitleURL?.path,
            englishSubtitleTrackID: selectedEnglishEmbeddedTrackID,
            chineseSubtitleKind: chineseSubtitleKind,
            chineseSubtitlePath: chineseExternalSubtitleURL?.path,
            chineseSubtitleTrackID: selectedChineseEmbeddedTrackID
        )

        guard draft != lastSavedVideoState else { return }
        playbackLog.debug("Saving playback position: \(draft.lastPositionMilliseconds)")

        do {
            try repository.saveVideoState(draft)
            lastSavedVideoState = draft
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func restoreSubtitleSelectionState(
        from record: VideoLearningRecord?
    ) {
        englishSubtitleKind = record?.englishSubtitleKind ?? .automatic
        chineseSubtitleKind = record?.chineseSubtitleKind ?? .automatic
        englishExternalSubtitleURL = record?.englishSubtitlePath.map {
            URL(fileURLWithPath: $0)
        }
        chineseExternalSubtitleURL = record?.chineseSubtitlePath.map {
            URL(fileURLWithPath: $0)
        }
        selectedEnglishEmbeddedTrackID = nil
        selectedChineseEmbeddedTrackID = nil
    }

    private func updateActiveSubtitles(at milliseconds: Int64) {
        let english = englishTimeline.activeCues(at: sourceTime(milliseconds, for: .english))
        if activeEnglish != english { activeEnglish = english }
        let chinese = chineseTimeline.activeCues(at: sourceTime(milliseconds, for: .chinese))
        if activeChinese != chinese { activeChinese = chinese }
    }

    private func handlePlaybackTime(_ milliseconds: Int64) {
        if let started = replayStarted, let practice = listeningPractice, playerController.isPlaying,
           playerController.pendingSeekMilliseconds == nil,
           milliseconds > practice.startMilliseconds, milliseconds < practice.endMilliseconds {
            replayStarted = nil
            started(PlaybackSpeed(savedRate: playerController.playbackRate))
        }
        if let practice = listeningPractice, sentenceLoop == nil,
           milliseconds >= practice.endMilliseconds {
            finishListeningPass(practice)
            return
        }
        if enforceSentenceLoop(at: milliseconds) {
            return
        }
        updateActiveSubtitles(at: milliseconds)
    }

    private func finishListeningPass(_ practice: ListeningPractice) {
        guard !hasFinishedListeningPass, listeningBoundaryTask == nil else { return }
        let generation = listeningPlaybackGeneration
        // @Published time emits before assigning. Defer player writes until
        // that emission has finished, and invalidate them on every new action.
        listeningBoundaryTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  listeningPlaybackGeneration == generation,
                  listeningPractice == practice, sentenceLoop == nil else { return }
            hasFinishedListeningPass = true
            playerController.pause()
            // Stay inside the half-open source interval so both subtitles remain.
            playerController.seek(toMilliseconds: practice.endMilliseconds - 1)
            listeningBoundaryTask = nil
        }
    }

    private func enforceSentenceLoop(at milliseconds: Int64) -> Bool {
        guard let sentenceLoop else { return false }

        let needsRestart =
            milliseconds < sentenceLoop.startMilliseconds - 250
            || milliseconds >= sentenceLoop.endMilliseconds
        guard needsRestart else {
            return false
        }
        guard !isRestartingSentenceLoop else {
            return true
        }

        scheduleSentenceLoopRestart(sentenceLoop)
        return true
    }

    private func scheduleSentenceLoopRestart(_ sentenceLoop: SentenceLoop) {
        guard !isRestartingSentenceLoop else { return }

        isRestartingSentenceLoop = true
        sentenceLoopRestartTask?.cancel()
        sentenceLoopRestartTask = Task { [weak self] in
            await Task.yield()
            guard self?.sentenceLoop == sentenceLoop else { return }
            self?.playerController.seek(
                toMilliseconds: sentenceLoop.startMilliseconds
            )

            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard self?.sentenceLoop == sentenceLoop else { return }
            self?.isRestartingSentenceLoop = false
            if let currentMilliseconds = self?.playerController.currentMilliseconds {
                _ = self?.enforceSentenceLoop(at: currentMilliseconds)
            }
        }
    }

    private func clearSubtitles() {
        setListeningFirst(false)
        stopSentenceLoop()
        englishSubtitleTask?.cancel()
        chineseSubtitleTask?.cancel()
        englishSubtitleGeneration = UUID()
        chineseSubtitleGeneration = UUID()
        userSelectedEnglishSubtitle = false
        userSelectedChineseSubtitle = false
        englishCues = []
        chineseCues = []
        activeEnglish = []
        activeChinese = []
        englishTimeline = SubtitleTimeline(cues: [])
        chineseTimeline = SubtitleTimeline(cues: [])
        embeddedSubtitleTracks = []
        selectedEnglishEmbeddedTrackID = nil
        selectedChineseEmbeddedTrackID = nil
        englishSubtitleKind = .automatic
        chineseSubtitleKind = .automatic
        englishExternalSubtitleURL = nil
        chineseExternalSubtitleURL = nil

        subtitleNotice = nil
    }





    private func discoverAndLoadEmbeddedSubtitles(
        from sourceURL: URL,
        loadID: UUID,
        restoredRecord: VideoLearningRecord?
    ) async {
        do {
            let tracks = try await embeddedSubtitleService.discoverTracks(in: sourceURL)
            try Task.checkCancellation()
            guard mediaLoadID == loadID,
                  currentSourceVideoURL?.standardizedFileURL == sourceURL else {
                return
            }

            embeddedSubtitleTracks = tracks
            let textTracks = tracks.filter(\.isTextBased)
            let englishTrack = preferredTrack(
                in: textTracks,
                languageCodes: ["en", "eng"]
            ) ?? (textTracks.count == 1 ? textTracks.first : nil)
            let chineseTrack = preferredTrack(
                in: textTracks,
                languageCodes: ["zh", "zho", "chi", "chs", "cht"]
            )

            do { try await restoreSubtitle(
                language: .english,
                sourceURL: sourceURL,
                tracks: textTracks,
                automaticTrack: englishTrack,
                restoredTrackID: restoredRecord?.englishSubtitleTrackID,
                externalPath: restoredRecord?.englishSubtitlePath
            ) } catch is CancellationError { throw CancellationError() }
              catch { subtitleNotice = "英文字幕读取失败：\(error.localizedDescription)；视频和另一条字幕仍可使用。" }
            do { try await restoreSubtitle(
                language: .chinese,
                sourceURL: sourceURL,
                tracks: textTracks,
                automaticTrack: chineseTrack,
                restoredTrackID: restoredRecord?.chineseSubtitleTrackID,
                externalPath: restoredRecord?.chineseSubtitlePath
            ) } catch is CancellationError { throw CancellationError() }
              catch { subtitleNotice = "中文字幕读取失败：\(error.localizedDescription)；视频和英文字幕仍可使用。" }

            let imageTrackCount = tracks.filter { !$0.isTextBased }.count
            if imageTrackCount > 0 {
                subtitleNotice = "发现 \(imageTrackCount) 条图像字幕轨道；这类字幕暂时不能用于 AI 文本分析。"
            }
        } catch is CancellationError {
            return
        } catch {
            guard mediaLoadID == loadID,
                  currentSourceVideoURL?.standardizedFileURL == sourceURL else {
                return
            }
            subtitleNotice = "内嵌字幕读取失败：\(error.localizedDescription)"
        }
    }

    private func restoreSubtitle(
        language: SubtitleLanguage,
        sourceURL: URL,
        tracks: [EmbeddedSubtitleTrack],
        automaticTrack: EmbeddedSubtitleTrack?,
        restoredTrackID: Int?,
        externalPath: String?
    ) async throws {
        if language == .english ? userSelectedEnglishSubtitle : userSelectedChineseSubtitle { return }
        let kind = language == .english
            ? englishSubtitleKind
            : chineseSubtitleKind

        switch kind {
        case .none:
            return
        case .external:
            guard let externalPath else {
                setSubtitleKind(.automatic, language: language)
                if let automaticTrack {
                    try await applyEmbeddedSubtitle(
                        automaticTrack,
                        language: language,
                        sourceURL: sourceURL
                    )
                }
                return
            }
            let subtitleURL = URL(fileURLWithPath: externalPath)
            guard FileManager.default.fileExists(atPath: subtitleURL.path) else {
                subtitleNotice = "上次使用的字幕文件不存在：\(subtitleURL.lastPathComponent)"
                return
            }
            try applyExternalSubtitle(subtitleURL, language: language)
        case .embedded:
            if let restoredTrackID,
               let track = tracks.first(where: { $0.id == restoredTrackID }) {
                try await applyEmbeddedSubtitle(
                    track,
                    language: language,
                    sourceURL: sourceURL
                )
            } else if let automaticTrack {
                try await applyEmbeddedSubtitle(
                    automaticTrack,
                    language: language,
                    sourceURL: sourceURL
                )
            }
        case .automatic:
            if let automaticTrack {
                try await applyEmbeddedSubtitle(
                    automaticTrack,
                    language: language,
                    sourceURL: sourceURL
                )
            }
        }
    }

    private func applyExternalSubtitle(
        _ url: URL,
        language: SubtitleLanguage
    ) throws {
        let result = try SRTParser.parse(data: Data(contentsOf: url))
        switch language {
        case .english:
            englishSubtitleKind = .external
            englishExternalSubtitleURL = url.standardizedFileURL
            selectedEnglishEmbeddedTrackID = nil
            englishCues = result.cues
            englishTimeline = SubtitleTimeline(cues: result.cues)
        case .chinese:
            chineseSubtitleKind = .external
            chineseExternalSubtitleURL = url.standardizedFileURL
            selectedChineseEmbeddedTrackID = nil
            chineseCues = result.cues
            chineseTimeline = SubtitleTimeline(cues: result.cues)
        }
        updateActiveSubtitles(at: playerController.confirmedMilliseconds)
        if result.skippedBlockCount > 0 {
            subtitleNotice = "已跳过 \(result.skippedBlockCount) 条无法解析的字幕。"
        }
    }

    private func applyEmbeddedSubtitle(
        _ track: EmbeddedSubtitleTrack,
        language: SubtitleLanguage,
        sourceURL: URL
    ) async throws {
        let generation = language == .english ? englishSubtitleGeneration : chineseSubtitleGeneration
        let data = try await embeddedSubtitleService.extract(
            track: track,
            from: sourceURL
        )
        let result = try SRTParser.parse(data: data)
        try Task.checkCancellation()
        guard currentSourceVideoURL?.standardizedFileURL == sourceURL,
              generation == (language == .english ? englishSubtitleGeneration : chineseSubtitleGeneration) else {
            return
        }

        switch language {
        case .english:
            selectedEnglishEmbeddedTrackID = track.id
            englishCues = result.cues
            englishTimeline = SubtitleTimeline(cues: result.cues)
            englishSubtitleKind = .embedded
            englishExternalSubtitleURL = nil
        case .chinese:
            selectedChineseEmbeddedTrackID = track.id
            chineseCues = result.cues
            chineseTimeline = SubtitleTimeline(cues: result.cues)
            chineseSubtitleKind = .embedded
            chineseExternalSubtitleURL = nil
        }
        updateActiveSubtitles(at: playerController.confirmedMilliseconds)

        if result.skippedBlockCount > 0 {
            subtitleNotice = "已跳过 \(result.skippedBlockCount) 条无法解析的内嵌字幕。"
        }
        saveCurrentVideoState()
    }

    private func invalidateSubtitleSelection(_ language: SubtitleLanguage) {
        if language == .english {
            setListeningFirst(false)
            englishSubtitleTask?.cancel()
            englishSubtitleGeneration = UUID()
            userSelectedEnglishSubtitle = true
        } else {
            chineseSubtitleTask?.cancel()
            chineseSubtitleGeneration = UUID()
            userSelectedChineseSubtitle = true
        }
    }

    private func setSubtitleKind(
        _ kind: StoredSubtitleKind,
        language: SubtitleLanguage
    ) {
        switch language {
        case .english:
            englishSubtitleKind = kind
        case .chinese:
            chineseSubtitleKind = kind
        }
    }

    private func preferredTrack(
        in tracks: [EmbeddedSubtitleTrack],
        languageCodes: Set<String>
    ) -> EmbeddedSubtitleTrack? {
        let matches = tracks.filter {
            guard let code = $0.normalizedLanguageCode else { return false }
            return languageCodes.contains(code)
        }
        return matches.first(where: \.isDefault) ?? matches.first
    }

    private enum Keys {
        static let legacyExportDestination = "legacyExportDestination"
        static let authorizedObsidianDirectory = "authorizedObsidianDirectory"
        static let englishReadingMode = "englishReadingMode"
        static let obsidianVaultPath = "obsidianVaultPath"
    }
}
