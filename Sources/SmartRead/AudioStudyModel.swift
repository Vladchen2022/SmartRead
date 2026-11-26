import AVFoundation
import Observation

@MainActor
@Observable
final class AudioStudyModel {
    struct SourceJump: Equatable {
        let cueID: UUID
        private let id = UUID()
    }

    private(set) var unreadableRecords: [URL] = []
    private(set) var history: [AudioStudyEntry] = []
    private(set) var entry: AudioStudyEntry?
    private(set) var position: Double = 0
    private(set) var focusedCueID: UUID?
    private(set) var questionSelection: AssistantQuestionSelection?
    private(set) var sourceJump: SourceJump?
    private(set) var isPlaying = false
    private(set) var playbackSpeed: PlaybackSpeed
    private(set) var waitingForNext = false
    private(set) var isImporting = false
    private(set) var transcriptionStatus: String?
    private(set) var transcriptionError: String?
    var issue: String?

    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private let store: AudioStudyStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tickObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var transcription: Task<Void, Never>?
    @ObservationIgnored private var seekID = UUID()
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var cueInPlayback: UUID?
    @ObservationIgnored private var playbackEnd: Double?
    @ObservationIgnored private var savedPosition: Double = 0

    init(store: AudioStudyStore = AudioStudyStore(), player: AVPlayer = AVPlayer(), defaults: UserDefaults = .standard) {
        self.store = store
        self.player = player
        self.defaults = defaults
        let speed = PlaybackSpeed(rawValue: defaults.float(forKey: "audioPlaybackSpeed")) ?? .normal
        playbackSpeed = speed
        player.defaultRate = speed.rawValue
    }

    deinit {
        if let tickObserver { player.removeTimeObserver(tickObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        transcription?.cancel()
    }

    var duration: Double { entry?.duration ?? 0 }
    var cues: [AudioStudyCue] { entry?.cues ?? [] }
    var focusedCueIndex: Int? { cues.firstIndex { $0.id == focusedCueID } }
    var canReplay: Bool { focusedCueID != nil || entry?.nextPlayableCue(at: position) != nil }

    func restore() {
        guard entry == nil, !isImporting else { return }
        do {
            let inventory = try store.inventory()
            history = inventory.entries
            unreadableRecords = inventory.unreadable
            if let previous = history.first(where: hasMedia) { open(previous.id) }
        } catch {
            issue = "无法读取音频历史。\n\(error.localizedDescription)"
        }
    }

    func hasMedia(_ entry: AudioStudyEntry) -> Bool {
        FileManager.default.isReadableFile(atPath: store.mediaURL(for: entry).path)
    }

    func relink(_ url: URL, to item: AudioStudyEntry) async throws {
        try await store.relink(url, to: item)
        if entry?.id == item.id { pause(); entry = nil }
        open(item.id)
    }

    func importMedia(_ source: URL) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let imported = try await store.add(source)
                history.insert(imported, at: 0)
                open(imported.id)
            } catch {
                issue = "无法导入 \(source.lastPathComponent)。\n\(error.localizedDescription)"
            }
        }
    }

    func open(_ id: UUID) {
        guard entry?.id != id, var item = history.first(where: { $0.id == id }) else { return }
        guard hasMedia(item) else { issue = "音频文件缺失，请在音频历史中重新关联。"; return }
        pause()
        transcription?.cancel()
        transcription = nil
        transcriptionStatus = nil
        transcriptionError = nil
        item.lastOpened = .now
        questionSelection = nil
        entry = item
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history.remove(at: index)
            history.insert(item, at: 0)
        }
        savedPosition = item.position
        installPlayerItem(AVPlayerItem(url: store.mediaURL(for: item)))
        move(to: item.position, play: false)
        saveProgress()
        if item.cues == nil { transcribe() }
    }

    func transcribe() {
        guard let entry, transcription == nil else { return }
        guard AudioStudyTranscriber.isAvailable else {
            transcriptionError = "本机字幕需要支持 Apple 语音转写的 Mac 和 macOS 26 或更新版本。"
            return
        }
        let id = entry.id
        transcriptionError = nil
        transcriptionStatus = "正在准备转写…"
        transcription = Task { [weak self, store] in
            defer {
                if let self, self.entry?.id == id, !Task.isCancelled {
                    self.transcriptionStatus = nil
                    self.transcription = nil
                }
            }
            do {
                let cues = try await AudioStudyTranscriber.transcribe(store.mediaURL(for: entry), entry: entry) { status in
                    guard let self, self.entry?.id == id, !Task.isCancelled else { return }
                    self.transcriptionStatus = status
                }
                try Task.checkCancellation()
                guard let self, var current = self.entry, current.id == id else { return }
                guard !cues.isEmpty else {
                    throw ReaderError.message("这段音频里没有识别到英文。")
                }
                current.cues = cues
                current.position = self.position
                try self.persist(current)
                self.updateFocus()
            } catch {
                guard let self, !Task.isCancelled, self.entry?.id == id else { return }
                self.transcriptionError = "字幕生成失败。\n\(error.localizedDescription)"
            }
        }
    }

    func togglePlayback() {
        guard entry != nil else { return }
        if isPlaying { pause() }
        else { move(to: position >= duration - 0.05 ? 0 : position, play: true) }
    }

    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        guard speed != playbackSpeed else { return }
        playbackSpeed = speed
        defaults.set(speed.rawValue, forKey: "audioPlaybackSpeed")
        player.defaultRate = speed.rawValue
        if isPlaying, !isSeeking, player.rate > 0 {
            player.rate = speed.rawValue
        }
    }

    func pause() {
        guard entry != nil else { return }
        if !isSeeking { updatePosition() }
        player.pause()
        isPlaying = false
        saveProgress()
    }

    func seek(to seconds: Double) {
        move(to: seconds, play: isPlaying)
        saveProgress()
    }

    func replay() {
        if let id = focusedCueID { playCue(id, selectsForQuestion: false) }
        else if let index = entry?.nextPlayableCue(at: position) {
            playCue(cues[index].id, selectsForQuestion: false)
        }
    }

    func canMoveCue(by offset: Int) -> Bool {
        cues.indices.contains((focusedCueIndex ?? -1) + offset)
    }

    func moveCue(by offset: Int) {
        let target = (focusedCueIndex ?? -1) + offset
        guard cues.indices.contains(target) else { return }
        playCue(cues[target].id)
    }

    func playCue(_ id: UUID, selectsForQuestion: Bool = true) {
        guard let index = cues.firstIndex(where: { $0.id == id }),
              let entry, let range = entry.playbackRange(for: index) else { return }
        if selectsForQuestion, let selection = AudioSubtitleSelection(entry: entry, cueID: id) {
            selectQuestionReference(selection)
        }
        move(to: range.lowerBound, play: true, cueID: id, end: range.upperBound)
    }

    func selectQuestionReference(_ selection: AudioSubtitleSelection) {
        guard let entry, let reference = selection.questionReference(in: entry) else { return }
        questionSelection = AssistantQuestionSelection(reference: reference)
    }

    func locateCue(_ id: UUID) {
        guard let cue = cues.first(where: { $0.id == id }) else { return }
        move(to: cue.start, play: false)
        sourceJump = SourceJump(cueID: id)
        saveProgress()
    }

    func locateQuestionSource(_ reference: AssistantQuestionReference, excerpt: NSRange?) throws {
        guard case let .audio(entryID, cueID, originalRange)? = reference.source?.location else { return }
        restore()
        let target = entry?.id == entryID ? entry : history.first { $0.id == entryID }
        guard let target, FileManager.default.isReadableFile(atPath: store.mediaURL(for: target).path),
              let cue = target.cues?.first(where: { $0.id == cueID }),
              reference.sourceRange(in: cue.text, at: originalRange, excerpt: excerpt) != nil else {
            throw ReaderError.message("找不到这条问答的音频原句。音频或字幕可能已修改。")
        }
        if entry?.id != entryID { open(entryID) }
        locateCue(cueID)
    }

    func editCue(_ cue: AudioStudyCue) throws {
        guard var entry, var cues = entry.cues, let index = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        let lower = index > 0 ? cues[index - 1].end : 0
        let upper = index + 1 < cues.count ? cues[index + 1].start : entry.duration
        guard cue.start.isFinite, cue.end.isFinite, cue.start >= lower, cue.end <= upper, cue.end > cue.start else {
            throw ReaderError.message("起点必须早于终点，并且不能与相邻字幕重叠。")
        }
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReaderError.message("请输入字幕文字。") }
        var updated = cue
        updated.text = text
        cues[index] = updated
        entry.cues = cues
        entry.position = position
        try persist(entry)
        if cueInPlayback == cue.id {
            pause()
            player.currentItem?.forwardPlaybackEndTime = .invalid
            playbackEnd = nil
            waitingForNext = true
        }
        updateFocus()
    }

    private func installPlayerItem(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.playbackEnded()
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                                 object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else { return }
                self.pause()
                self.issue = "无法播放这个文件的音轨。"
            }
        }
        if tickObserver == nil {
            tickObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
                                                         queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updatePosition() }
            }
        }
    }

    private func move(to seconds: Double, play: Bool, cueID: UUID? = nil, end: Double? = nil) {
        guard seconds.isFinite, let item = player.currentItem else { return }
        let target = min(max(0, seconds), duration)
        let id = UUID()
        seekID = id
        isSeeking = true
        player.pause()
        cueInPlayback = cueID
        waitingForNext = false
        playbackEnd = end
        isPlaying = play
        position = target
        item.forwardPlaybackEndTime = end.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid
        updateFocus()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekID == id else { return }
                self.isSeeking = false
                guard finished else {
                    self.isPlaying = false
                    return
                }
                if self.isPlaying { self.player.play() }
            }
        }
    }

    private func playbackEnded() {
        guard !isSeeking, isPlaying else { return }
        let end = playbackEnd ?? duration
        guard player.currentTime().seconds >= end - 0.08 else { return }
        player.pause()
        position = end
        isPlaying = false
        waitingForNext = cueInPlayback != nil
        updateFocus()
        saveProgress()
    }

    private func updatePosition() {
        guard !isSeeking, entry != nil else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        if isPlaying, player.rate == 0, seconds >= (playbackEnd ?? duration) - 0.03 {
            playbackEnded()
            return
        }
        position = min(max(0, seconds), duration)
        updateFocus()
        if isPlaying, abs(position - savedPosition) >= 5 { saveProgress() }
    }

    private func updateFocus() {
        let next = cueInPlayback ?? entry?.cueIndex(at: position).map { cues[$0].id }
        if next != focusedCueID { focusedCueID = next }
    }

    private func saveProgress() {
        guard var entry else { return }
        entry.position = position
        do {
            try store.saveProgress(entry)
            self.entry = entry
            savedPosition = position
            if let index = history.firstIndex(where: { $0.id == entry.id }) { history[index] = entry }
        } catch {
            savedPosition = position
            issue = "音频进度无法保存。\n\(error.localizedDescription)"
        }
    }

    private func persist(_ entry: AudioStudyEntry) throws {
        try store.saveProgress(entry)
        try store.save(entry)
        self.entry = entry
        savedPosition = entry.position
        if let index = history.firstIndex(where: { $0.id == entry.id }) {
            history[index] = entry
            history.sort { $0.lastOpened > $1.lastOpened }
        }
    }
}
