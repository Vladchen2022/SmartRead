import AVFoundation
import Observation

@MainActor
@Observable
final class ReaderSpeech: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    enum Engine: String, CaseIterable {
        case mac, kokoro

        var title: String { self == .mac ? "Mac 内建语音" : "Kokoro 82M" }
    }

    enum Phase: Equatable { case ready, positioning, loading, playing, paused }

    struct FocusRequest: Equatable {
        let id = UUID()
        let range: NSRange
    }

    let macVoices = AVSpeechSynthesisVoice.speechVoices().filter {
        $0.language.hasPrefix("en-") && !$0.voiceTraits.contains(.isNoveltyVoice)
    }.sorted { ($0.language, $0.name, -$0.quality.rawValue) < ($1.language, $1.name, -$1.quality.rawValue) }
    var engine: Engine {
        didSet {
            guard oldValue != engine else { return }
            defaults.set(engine.rawValue, forKey: "speechEngine")
            outputChanged()
            warmUp()
        }
    }
    var macVoice: String {
        didSet {
            defaults.set(macVoice, forKey: "speechMacVoice")
            if engine == .mac { outputChanged() }
        }
    }
    var kokoroVoice: String {
        didSet {
            defaults.set(kokoroVoice, forKey: "speechKokoroVoice")
            if engine == .kokoro { outputChanged() }
        }
    }
    private(set) var phase: Phase = .ready
    private(set) var playbackSpeed: PlaybackSpeed
    private(set) var error: String?
    private(set) var index = 0
    private(set) var focusRequest: FocusRequest?
    private(set) var singleSentence = false
    private(set) var waitingForNext = false
    private(set) var lastSpoken: TextExcerpt?
    private(set) var isPreviewing = false
    private(set) var isBlindListening = false
    private var sentences: [TextExcerpt] = []
    private var selectionContinuation: [TextExcerpt] = []

    private let defaults: UserDefaults
    private let synthesizer = AVSpeechSynthesizer()
    private let kokoro = KokoroEngine()
    private var utterance: AVSpeechUtterance?
    private var audio: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var replayStarted: ((PlaybackSpeed) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playbackSpeed = PlaybackSpeed(savedRate: defaults.float(forKey: "speechPlaybackSpeed"))
        engine = defaults.string(forKey: "speechEngine").flatMap(Engine.init(rawValue:)) ?? .mac
        macVoice = defaults.string(forKey: "speechMacVoice") ?? ""
        kokoroVoice = defaults.string(forKey: "speechKokoroVoice") ?? "af_heart"
        super.init()
        synthesizer.delegate = self
    }

    var current: TextExcerpt? { sentences.indices.contains(index) ? sentences[index] : nil }
    var count: Int { sentences.count }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { hasQueuedNext || !selectionContinuation.isEmpty }
    var isActive: Bool { phase == .playing || phase == .loading || phase == .positioning }
    private var hasQueuedNext: Bool { index + 1 < sentences.count }

    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        guard speed != playbackSpeed else { return }
        playbackSpeed = speed
        defaults.set(speed.rawValue, forKey: "speechPlaybackSpeed")
        audio?.rate = speed.rawValue
    }

    func warmUp() {
        guard engine == .kokoro, KokoroEngine.isInstalled else { return }
        Task { try? await kokoro.prepare() }
    }

    func start(_ source: [TextExcerpt], at position: Int = 0, selectionContinuation: [TextExcerpt] = [],
               stopsAfterSentence: Bool = false, onStarted: ((PlaybackSpeed) -> Void)? = nil) {
        guard source.indices.contains(position) else { return }
        cancelOutput()
        isPreviewing = false
        sentences = source
        self.selectionContinuation = selectionContinuation
        index = position
        singleSentence = stopsAfterSentence
        lastSpoken = nil
        replayStarted = onStarted
        playCurrent()
    }

    func preview(_ sentence: TextExcerpt) {
        stop()
        isPreviewing = true
        playSpeech(sentence)
    }

    func replay(onStarted: ((PlaybackSpeed) -> Void)? = nil) {
        guard current != nil else { return }
        singleSentence = true
        cancelOutput()
        replayStarted = onStarted
        playCurrent()
    }

    func move(_ offset: Int) {
        let next = index + offset
        if offset == 1, next == sentences.count, !selectionContinuation.isEmpty {
            sentences.append(contentsOf: selectionContinuation)
            selectionContinuation.removeAll()
        }
        guard sentences.indices.contains(next) else { return }
        index = next
        replay()
    }

    func stop() {
        isPreviewing = false
        isBlindListening = false
        cancelOutput()
        sentences = []
        lastSpoken = nil
        selectionContinuation = []
        index = 0
        error = nil
        focusRequest = nil
        singleSentence = false
        waitingForNext = false
    }

    func setBlindListening(_ enabled: Bool) {
        guard enabled != isBlindListening, !enabled || current != nil else { return }
        isBlindListening = enabled
        if enabled, let focusRequest { focusArrived(focusRequest.id) }
    }

    func toggle() {
        singleSentence = false
        if isActive {
            pause()
        } else {
            if waitingForNext, hasQueuedNext { index += 1 }
            playCurrent()
        }
    }

    func pause() {
        guard !isPreviewing else { stop(); return }
        switch phase {
        case .playing:
            if let audio { audio.pause() }
            else if !synthesizer.pauseSpeaking(at: .immediate) { cancelOutput() }
            phase = .paused
        case .loading, .positioning:
            cancelOutput()
            phase = .paused
        case .paused, .ready:
            break
        }
    }

    private func outputChanged() {
        if isPreviewing { stop(); return }
        guard current != nil else { return }
        let resume = isActive
        cancelOutput()
        error = nil
        if resume { playCurrent() }
    }

    private func cancelOutput() {
        replayStarted = nil
        playbackTask?.cancel()
        playbackTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        audio?.stop()
        audio = nil
        phase = .ready
    }

    private func playCurrent() {
        guard let current else { return }
        waitingForNext = false
        error = nil
        let request = FocusRequest(range: current.range)
        focusRequest = request
        phase = .positioning
        if isBlindListening { focusArrived(request.id) }
    }

    func focusArrived(_ id: UUID) {
        guard focusRequest?.id == id, phase == .positioning, let current else { return }
        if let audio, audio.play() {
            phase = .playing
            return
        }
        if utterance != nil, synthesizer.continueSpeaking() {
            phase = .playing
            return
        }
        if audio != nil || utterance != nil { cancelOutput() }
        playSpeech(current)
    }

    private func playSpeech(_ excerpt: TextExcerpt) {
        phase = .loading
        switch engine {
        case .mac:
            let next = AVSpeechUtterance(string: excerpt.text)
            next.voice = AVSpeechSynthesisVoice(identifier: macVoice)
                ?? macVoices.filter { $0.language == "en-US" && $0.quality != .default }
                    .max(by: { $0.quality.rawValue < $1.quality.rawValue })
                ?? AVSpeechSynthesisVoice(language: "en-US")
            next.rate = AVSpeechUtteranceDefaultSpeechRate * playbackSpeed.rawValue
            utterance = next
            synthesizer.speak(next)
        case .kokoro:
            let voice = kokoroVoice
            let manualStep = singleSentence
            playbackTask = Task { [weak self, kokoro] in
                do {
                    if manualStep { try await Task.sleep(for: .milliseconds(90)) }
                    let data = try await kokoro.audio(for: excerpt.text, voice: voice)
                    guard let self, !Task.isCancelled else { return }
                    let next = try AVAudioPlayer(data: data)
                    next.delegate = self
                    next.enableRate = true
                    next.rate = self.playbackSpeed.rawValue
                    guard next.play() else { throw ReaderError.message("音频未能播放。") }
                    self.audio = next
                    self.phase = .playing
                    if !self.isPreviewing {
                        self.lastSpoken = excerpt
                        self.confirmReplay(PlaybackSpeed(savedRate: next.rate))
                        self.prefetchNext(voice: voice)
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func prefetchNext(voice: String) {
        let next = hasQueuedNext ? sentences[index + 1] : selectionContinuation.first
        guard let following = next?.text else { return }
        prefetchTask = Task(priority: .utility) { [kokoro] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                _ = try await kokoro.audio(for: following, voice: voice)
            } catch { /* Playback will request the sentence itself if needed. */ }
        }
    }

    private func fail(_ message: String) {
        isPreviewing = false
        cancelOutput()
        focusRequest = nil
        error = message
    }

    private func finishSentence() {
        if isPreviewing { stop(); return }
        replayStarted = nil
        utterance = nil
        audio = nil
        if singleSentence || phase == .paused {
            waitingForNext = true
            phase = .paused
        } else if hasQueuedNext {
            index += 1
            playCurrent()
        } else {
            waitingForNext = !selectionContinuation.isEmpty
            focusRequest = nil
            phase = .ready
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let speed = PlaybackSpeed(savedRate: utterance.rate / AVSpeechUtteranceDefaultSpeechRate)
        Task { @MainActor [weak self] in
            guard let self, self.phase == .loading, let utterance = self.utterance, ObjectIdentifier(utterance) == id else { return }
            self.phase = .playing
            self.lastSpoken = self.current
            self.confirmReplay(speed)
        }
    }

    private func confirmReplay(_ speed: PlaybackSpeed) {
        let confirm = replayStarted
        replayStarted = nil
        confirm?(speed)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let utterance = self.utterance, ObjectIdentifier(utterance) == id else { return }
            self.finishSentence()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let audio = self.audio, ObjectIdentifier(audio) == id else { return }
            if flag { self.finishSentence() }
            else { self.fail("音频播放中断，请重试。") }
        }
    }
}
