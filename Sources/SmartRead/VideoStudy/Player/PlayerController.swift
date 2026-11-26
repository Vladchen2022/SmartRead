import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog
import VLCKit

enum PlayerError: LocalizedError {
    case unsupportedMedia
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unsupportedMedia:
            return "这个视频无法由播放器解码。"
        case .unreadableFile:
            return "无法读取视频文件。文件可能已被移动，或所在硬盘尚未连接。"
        }
    }
}

enum PlaybackBackend: Equatable {
    case avFoundation
    case vlc
}

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
}

struct VLCSeekCoordinator {
    enum Action: Equatable {
        case wait
        case issue(Int64)
        case abandon
    }

    // VLC can publish its assigned seek value before a decoded clock event.
    // Require actual forward movement, not an echo of the value just written.
    // The window also accommodates VLC's coarse clock events at 2× playback.
    static let targetToleranceMilliseconds: Int64 = 800
    static let retryInterval: TimeInterval = 1.5
    static let maximumAttempts = 2

    private(set) var targetMilliseconds: Int64?
    private(set) var attemptCount = 0
    private var lastAttemptUptime: TimeInterval?
    private var clockAtSubmission: Int64?

    mutating func schedule(targetMilliseconds: Int64) {
        self.targetMilliseconds = targetMilliseconds
        attemptCount = 0
        lastAttemptUptime = nil
        clockAtSubmission = nil
    }

    mutating func cancel() {
        targetMilliseconds = nil
        attemptCount = 0
        lastAttemptUptime = nil
        clockAtSubmission = nil
    }

    @discardableResult
    mutating func observe(
        reportedMilliseconds: Int64,
        isPlaybackAdvancing: Bool = true
    ) -> Bool {
        // VLCKit's time is an event-driven cache. A paused input can complete
        // a seek without publishing a new time event. Keep the user's latest
        // target until playback resumes; that stale cache is not an ack/failure.
        guard isPlaybackAdvancing, attemptCount > 0, reportedMilliseconds != clockAtSubmission,
              let targetMilliseconds else { return false }
        let progress = reportedMilliseconds - targetMilliseconds
        guard progress >= 20, progress <= Self.targetToleranceMilliseconds else {
            return false
        }

        cancel()
        return true
    }

    mutating func nextAction(
        isPlayerReady: Bool,
        isPlaybackAdvancing: Bool = true,
        uptime: TimeInterval,
        reportedMilliseconds: Int64? = nil
    ) -> Action {
        guard let targetMilliseconds else { return .wait }
        guard isPlayerReady else { return .wait }

        // Submit a paused seek once (so its frame can be decoded), but do not
        // retry or expire it against an unchanged paused clock. Rapid new seeks
        // replace this target and get their own single submission.
        if !isPlaybackAdvancing, attemptCount > 0 { return .wait }

        if let lastAttemptUptime,
           uptime - lastAttemptUptime < Self.retryInterval {
            return .wait
        }

        guard attemptCount < Self.maximumAttempts else {
            cancel()
            return .abandon
        }

        attemptCount += 1
        lastAttemptUptime = uptime
        clockAtSubmission = reportedMilliseconds
        return .issue(targetMilliseconds)
    }
}

@MainActor
final class PlayerController: ObservableObject {
    private let playbackLog = Logger(subsystem: "local.smartread.reader", category: "PlaybackState")
    let player = AVPlayer()
    private lazy var vlcPlayer = VLCMediaPlayer()

    @Published private(set) var backend: PlaybackBackend = .avFoundation
    @Published private(set) var currentURL: URL?
    @Published private(set) var currentMilliseconds: Int64 = 0
    @Published private(set) var confirmedMilliseconds: Int64 = 0
    @Published private(set) var pendingSeekMilliseconds: Int64?
    @Published private(set) var durationMilliseconds: Int64 = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isStarting = false
    @Published private(set) var playbackError: String?
    @Published private(set) var availableAudioTracks: [PlaybackTrack] = []
    @Published private(set) var selectedAudioTrackID: Int32?

    @Published var playbackRate: Float = 1.0 {
        didSet {
            player.defaultRate = playbackRate
            if usesVLC { vlcPlayer.rate = playbackRate }
            if isPlaying, backend == .avFoundation {
                player.rate = playbackRate
            }
        }
    }

    @Published var volume: Double = 1 {
        didSet {
            let adjusted = max(0, min(volume, 1))
            if adjusted != volume {
                volume = adjusted
                return
            }
            player.volume = Float(adjusted)
            if usesVLC {
                vlcPlayer.audio?.volume = Int32((adjusted * 100).rounded())
                vlcPlayer.audio?.isMuted = adjusted == 0
            }
        }
    }

    var usesVLC: Bool {
        backend == .vlc
    }

    private var requiresBackendSeekAcknowledgement: Bool {
        backend == .vlc ? vlcHasMediaData : player.currentItem != nil
    }

    private func publishConfirmedTime(_ milliseconds: Int64) {
        if currentMilliseconds != milliseconds { currentMilliseconds = milliseconds }
        if confirmedMilliseconds != milliseconds { confirmedMilliseconds = milliseconds }
    }

    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var lastVLCTrackSignature = ""
    private var vlcPollTick = 0
    private var vlcSeekCoordinator = VLCSeekCoordinator()
    private var startRequestedAt: TimeInterval?
    private var vlcPlaySubmitted = false
    private var mediaGeneration = UUID()
    private var avSeekGeneration = UUID()
    private var avPendingTarget: Int64?
    private var itemStatusObserver: AnyCancellable?
    private var itemEndObserver: AnyCancellable?
    private var wantsPlayback = false
    private var pausedVLCPosition: Int64?
    private var vlcHasMediaData = false

    init() {
        player.isMuted = false
        player.volume = 1
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = playbackRate

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] _ in
            // The callback is explicitly delivered on the main queue. Read the
            // current clock, not a timestamp queued before a newer seek.
            MainActor.assumeIsolated {
                guard let self, self.backend == .avFoundation, self.avPendingTarget == nil else { return }
                self.publishConfirmedTime(Self.milliseconds(from: self.player.currentTime()))
            }
        }

        player.publisher(for: \.timeControlStatus)
            .map { $0 == .playing }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self, backend == .avFoundation else { return }
                isPlaying = wantsPlayback && playing
                if wantsPlayback && playing { isStarting = false; startRequestedAt = nil }
            }
            .store(in: &cancellables)

        Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollVLCState()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pause() }
            .store(in: &cancellables)
    }

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func load(url: URL) async throws {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.isFileURL,
              FileManager.default.isReadableFile(atPath: standardizedURL.path) else {
            throw PlayerError.unreadableFile
        }
        resetStartupState()
        mediaGeneration = UUID()
        avSeekGeneration = UUID()
        avPendingTarget = nil
        pendingSeekMilliseconds = nil
        pausedVLCPosition = nil
        playbackError = nil
        if standardizedURL.pathExtension.lowercased() == "mkv" {
            loadWithVLC(url: standardizedURL)
        } else {
            try await loadWithAVFoundation(url: standardizedURL, generation: mediaGeneration)
        }
    }

    func togglePlayback() {
        if isPlaying || isStarting {
            pause()
            return
        }

        play()
    }

    func play() {
        playbackLog.notice("Play intent at \(self.currentMilliseconds), pending \(self.vlcSeekCoordinator.targetMilliseconds ?? -1), held \(self.pausedVLCPosition ?? -1)")
        guard currentURL != nil else { return }
        playbackError = nil
        switch backend {
        case .avFoundation:
            wantsPlayback = true
            isStarting = true
            startRequestedAt = ProcessInfo.processInfo.systemUptime
            player.playImmediately(atRate: playbackRate)
        case .vlc:
            guard !(wantsPlayback && (isStarting || vlcPlayer.isPlaying)) else { return }
            wantsPlayback = true
            isStarting = true
            startRequestedAt = ProcessInfo.processInfo.systemUptime
            vlcPlaySubmitted = false
            startVLCIfReady()
        }
    }

    func pause() {
        let wasStarting = isStarting
        let heldPosition = vlcSeekCoordinator.targetMilliseconds ?? currentMilliseconds
        playbackLog.notice("Pause intent at \(self.currentMilliseconds), holding \(heldPosition), starting \(self.isStarting)")
        resetStartupState()
        switch backend {
        case .avFoundation:
            player.pause()
        case .vlc:
            pausedVLCPosition = heldPosition
            if wasStarting, !vlcPlayer.isPlaying {
                vlcSeekCoordinator.schedule(targetMilliseconds: heldPosition)
                vlcPlayer.stop()
            } else if vlcPlayer.isPlaying || vlcPlayer.canPause {
                vlcPlayer.pause()
            }
            currentMilliseconds = heldPosition
        }
        isPlaying = false
    }

    func skip(milliseconds: Int64) {
        seek(toMilliseconds: currentMilliseconds + milliseconds)
    }

    func seek(toMilliseconds milliseconds: Int64) {
        playbackLog.notice("Seek requested \(milliseconds), before \(self.currentMilliseconds), wants \(self.wantsPlayback)")
        let upperBound = durationMilliseconds > 0
            ? durationMilliseconds
            : max(0, milliseconds)
        let bounded = max(0, min(milliseconds, upperBound))
        pendingSeekMilliseconds = requiresBackendSeekAcknowledgement ? bounded : nil

        switch backend {
        case .avFoundation:
            let time = CMTime(value: bounded, timescale: 1_000)
            let generation = UUID()
            avSeekGeneration = generation
            avPendingTarget = bounded
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, backend == .avFoundation, avSeekGeneration == generation else { return }
                    avPendingTarget = nil
                    pendingSeekMilliseconds = nil
                    if finished { publishConfirmedTime(Self.milliseconds(from: player.currentTime())) }
                    else if player.currentItem != nil {
                        publishConfirmedTime(Self.milliseconds(from: player.currentTime()))
                        playbackError = "视频跳转未完成，请重试。"
                    }
                }
            }
        case .vlc:
            if !wantsPlayback { pausedVLCPosition = bounded }
            vlcSeekCoordinator.schedule(targetMilliseconds: bounded)
            servicePendingVLCSeekIfReady()
        }
        currentMilliseconds = bounded
        if !requiresBackendSeekAcknowledgement { publishConfirmedTime(bounded) }
    }

    func close() {
        mediaGeneration = UUID()
        avSeekGeneration = UUID()
        avPendingTarget = nil
        pendingSeekMilliseconds = nil
        pausedVLCPosition = nil
        itemStatusObserver = nil
        itemEndObserver = nil
        vlcHasMediaData = false
        resetStartupState()
        playbackError = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearVLCMedia()

        currentURL = nil
        publishConfirmedTime(0)
        durationMilliseconds = 0
        isPlaying = false
        availableAudioTracks = []
        selectedAudioTrackID = nil
        lastVLCTrackSignature = ""
        vlcPollTick = 0
        vlcSeekCoordinator.cancel()
    }

    private func clearVLCMedia() {
        guard usesVLC else { return }
        vlcPlayer.stop()
        vlcPlayer.media = nil
        vlcPlayer.drawable = nil
    }

    func selectAudioTrack(_ id: Int32) {
        guard backend == .vlc else { return }
        vlcPlayer.currentAudioTrackIndex = id
        selectedAudioTrackID = id
    }

    func attachVLCDrawable(_ view: NSView) {
        guard usesVLC else { return }
        if vlcPlayer.drawable as AnyObject? !== view {
            vlcPlayer.drawable = view
        }
        startVLCIfReady()
    }

    func detachVLCDrawable(_ view: NSView) {
        guard usesVLC, vlcPlayer.drawable as AnyObject? === view else { return }
        vlcPlayer.drawable = nil
    }

    private func loadWithAVFoundation(url: URL, generation: UUID) async throws {
        clearVLCMedia()
        availableAudioTracks = []
        selectedAudioTrackID = nil
        lastVLCTrackSignature = ""
        vlcPollTick = 0
        vlcSeekCoordinator.cancel()

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw PlayerError.unsupportedMedia
        }

        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        guard mediaGeneration == generation else { throw CancellationError() }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        itemStatusObserver = item.publisher(for: \.status).receive(on: RunLoop.main).sink { [weak self, weak item] status in
            guard let self, mediaGeneration == generation, status == .failed else { return }
            pause()
            playbackError = "视频解码失败：\(item?.error?.localizedDescription ?? "容器可读，但编码不受系统支持。请尝试其他编码版本。")"
        }
        itemEndObserver = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, mediaGeneration == generation, avPendingTarget == nil else { return }
                resetStartupState()
                publishConfirmedTime(durationMilliseconds)
                if isPlaying { isPlaying = false }
            }
        backend = .avFoundation
        currentURL = url
        publishConfirmedTime(0)
        durationMilliseconds = Self.milliseconds(from: duration)
        isPlaying = false
        player.isMuted = volume == 0
        player.volume = Float(volume)
        player.defaultRate = playbackRate
    }

    private func loadWithVLC(url: URL) {
        playbackLog.notice("Loading VLC state reset")
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemEndObserver = nil
        vlcHasMediaData = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        vlcPlayer.stop()

        backend = .vlc
        currentURL = url
        publishConfirmedTime(0)
        durationMilliseconds = 0
        isPlaying = false
        availableAudioTracks = []
        selectedAudioTrackID = nil
        lastVLCTrackSignature = ""
        vlcPollTick = 0
        vlcSeekCoordinator.cancel()

        let media = VLCMedia(url: url)
        // SmartRead discovers embedded/external learning subtitles itself. VLC's
        // filename scan can otherwise walk an entire season folder before
        // playback starts.
        // VLC boolean options use the no- prefix. '=0' is still parsed as
        // enabling this flag and can block on subtitle search directories.
        media.addOption(":no-sub-autodetect-file")
        vlcPlayer.media = media
        vlcPlayer.rate = playbackRate
        vlcPlayer.audio?.isMuted = volume == 0
        vlcPlayer.audio?.volume = Int32((volume * 100).rounded())
    }

    private func pollVLCState() {
        guard backend == .vlc else {
            if isStarting, let startRequestedAt,
               ProcessInfo.processInfo.systemUptime - startRequestedAt > 15 {
                player.pause()
                resetStartupState()
                isPlaying = false
                playbackError = "视频在 15 秒内未能开始播放。可重试打开；字幕和本机学习记录不受影响。"
            }
            return
        }

        startVLCIfReady()
        if vlcPlaySubmitted, vlcPlayer.state == .error {
            failVLCPlayback("视频播放失败，请重新打开文件或选择另一个视频。")
            return
        }
        if vlcPlaySubmitted, !isStarting, vlcPlayer.state == .ended, durationMilliseconds > 0 {
            resetStartupState()
            vlcSeekCoordinator.cancel()
            pendingSeekMilliseconds = nil
            pausedVLCPosition = durationMilliseconds
            publishConfirmedTime(durationMilliseconds)
            if isPlaying { isPlaying = false }
            return
        }
        if isStarting, vlcPlayer.isPlaying {
            isStarting = false
            startRequestedAt = nil
        } else if let startRequestedAt,
                  ProcessInfo.processInfo.systemUptime - startRequestedAt > 15 {
            failVLCPlayback("视频在 15 秒内未能开始播放。请确认文件已完整下载、硬盘已连接，然后重试。")
            return
        }

        let timeValue = vlcPlayer.time.value?.int64Value ?? 0
        let previousPublishedTime = currentMilliseconds
        if timeValue >= 0,
           vlcSeekCoordinator.observe(
               reportedMilliseconds: timeValue,
               isPlaybackAdvancing: wantsPlayback && vlcPlayer.isPlaying
           ) {
            pausedVLCPosition = nil
            pendingSeekMilliseconds = nil
            publishConfirmedTime(timeValue)
        } else if let targetMilliseconds = vlcSeekCoordinator.targetMilliseconds {
            if currentMilliseconds != targetMilliseconds { currentMilliseconds = targetMilliseconds }
        } else if !wantsPlayback, let pausedVLCPosition {
            if currentMilliseconds != pausedVLCPosition { currentMilliseconds = pausedVLCPosition }
        } else if timeValue >= 0 {
            publishConfirmedTime(timeValue)
        }
        if previousPublishedTime > 1_000, currentMilliseconds == 0 {
            playbackLog.error("Clock fell to zero: native \(timeValue), pending \(self.vlcSeekCoordinator.targetMilliseconds ?? -1), held \(self.pausedVLCPosition ?? -1), wants \(self.wantsPlayback), state \(self.vlcPlayer.state.rawValue)")
        }

        servicePendingVLCSeekIfReady()

        let durationValue = vlcPlayer.media?.length.value?.int64Value ?? 0
        if durationValue > 0, durationValue != durationMilliseconds {
            durationMilliseconds = durationValue
        }

        let playing = wantsPlayback && vlcPlayer.isPlaying
        if isPlaying != playing { isPlaying = playing }
        vlcPollTick += 1
        if vlcPollTick % 10 == 0 {
            refreshVLCAudioTracks()

            // SmartRead renders its own selectable dual-subtitle area. Keeping VLC's
            // overlay disabled avoids a third, duplicated subtitle on the video.
            if vlcPlayer.currentVideoSubTitleIndex != -1 {
                vlcPlayer.currentVideoSubTitleIndex = -1
            }
        }
    }

    private func startVLCIfReady() {
        guard backend == .vlc, isStarting, !vlcPlaySubmitted,
              let view = vlcPlayer.drawable as? NSView,
              view.window != nil else { return }
        // Submit play once, after SwiftUI has installed the video surface.
        // Repeated play during opening can enqueue conflicting VLC controls.
        vlcPlaySubmitted = true
        vlcPlayer.rate = playbackRate
        vlcPlayer.play()
    }

    private func resetStartupState() {
        wantsPlayback = false
        isStarting = false
        startRequestedAt = nil
        vlcPlaySubmitted = false
    }

    private func failVLCPlayback(_ message: String) {
        resetStartupState()
        vlcSeekCoordinator.cancel()
        pendingSeekMilliseconds = nil
        vlcPlayer.stop()
        isPlaying = false
        playbackError = message
    }

    private func servicePendingVLCSeekIfReady() {
        let state = vlcPlayer.state
        let hasActiveInput = state == .buffering
            || state == .playing
            || state == .paused
        let action = vlcSeekCoordinator.nextAction(
            isPlayerReady: vlcPlayer.isSeekable && hasActiveInput,
            isPlaybackAdvancing: wantsPlayback && vlcPlayer.isPlaying,
            uptime: ProcessInfo.processInfo.systemUptime,
            reportedMilliseconds: vlcPlayer.time.value?.int64Value
        )

        switch action {
        case let .issue(milliseconds):
            vlcPlayer.time = VLCTime(number: NSNumber(value: milliseconds))
        case .abandon:
            // A genuinely failed active seek must not silently look successful.
            pause()
            pendingSeekMilliseconds = nil
            publishConfirmedTime(confirmedMilliseconds)
            pausedVLCPosition = confirmedMilliseconds
            playbackError = "未能跳转到所选位置，已暂停播放。请重试跳转或重新打开视频。"
        case .wait:
            break
        }
    }

    private func refreshVLCAudioTracks() {
        let names = vlcPlayer.audioTrackNames
        let indexes = vlcPlayer.audioTrackIndexes
        let signature = "\(names)|\(indexes)|\(vlcPlayer.currentAudioTrackIndex)"
        guard signature != lastVLCTrackSignature else { return }
        lastVLCTrackSignature = signature

        availableAudioTracks = zip(names, indexes).compactMap { name, index in
            guard let identifier = (index as? NSNumber)?.int32Value else {
                return nil
            }
            guard identifier >= 0 else { return nil }
            let displayName = (name as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return PlaybackTrack(
                id: identifier,
                name: displayName?.isEmpty == false
                    ? displayName!
                    : "音轨 \(identifier)"
            )
        }

        let currentID = vlcPlayer.currentAudioTrackIndex
        selectedAudioTrackID = availableAudioTracks.contains { $0.id == currentID }
            ? currentID
            : nil
    }

    private static func milliseconds(from time: CMTime) -> Int64 {
        guard time.isNumeric else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000).rounded())
    }
}
