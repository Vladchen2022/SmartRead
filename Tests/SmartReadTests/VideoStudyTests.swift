import AppKit
import XCTest
import VLCKit
@testable import SmartRead

@MainActor
final class VideoStudyTests: XCTestCase {
    func testMP4StepsAndReplaysOneSentenceThenResumesContinuousPlayback() async throws {
        let (model, suite) = try makeModel()
        defer { model.closeVideo(); suite.defaults.removePersistentDomain(forName: suite.name) }
        let controller = model.playerController
        model.openVideo(try fixture("mp4"), seekTo: 1_150)
        model.togglePlayback()
        try await wait { !model.isPreparingMedia && controller.pendingSeekMilliseconds == nil }
        model.loadSubtitle(try fixture("srt", name: "Playback.en"), language: .english)
        try await wait { model.displayedEnglishText.contains("first test sentence") }
        XCTAssertFalse(model.canStep(by: -1))

        let original = model.displayedEnglishText
        let phrase = SubtitleWord(text: "test sentence", range: (original as NSString).range(of: "test sentence"))
        model.lookupDisplayedWord(phrase, in: original)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(model.assistantPhraseRequest?.focusedWord?.text, phrase.text)
        XCTAssertEqual(model.sidebarSource?.sentence, original)
        XCTAssertEqual(model.questionReference(currentOnly: false)?.passage, original)
        XCTAssertEqual(model.questionReference(currentOnly: false)?.focus, phrase.text)
        XCTAssertEqual(model.questionSelection?.reference.focus, phrase.text)
        let linked = try XCTUnwrap(model.questionSelection?.reference)

        model.step(by: 1)
        try await wait { model.hasFinishedListeningPass && !controller.isPlaying }
        XCTAssertTrue(model.displayedEnglishText.contains("second test sentence"))
        XCTAssertEqual(controller.currentMilliseconds, 4_999, accuracy: 100)
        XCTAssertEqual(model.questionReference(currentOnly: false)?.passage, original)
        XCTAssertTrue(model.questionReference(currentOnly: true)?.passage.contains("second test sentence") == true)
        XCTAssertTrue(model.questionSelection?.reference.passage.contains("second test sentence") == true)

        model.analyzeAssistantSentence()
        XCTAssertEqual(model.selectedSubtitle?.english, original)
        try await model.locateQuestionSource(linked, excerpt: try XCTUnwrap(linked.linkRange(for: phrase.text)))
        XCTAssertFalse(controller.isPlaying)
        try await wait { controller.pendingSeekMilliseconds == nil && model.displayedEnglishText == original }
        XCTAssertEqual(controller.currentMilliseconds, model.englishCues[0].startMilliseconds, accuracy: 100)

        model.step(by: 1)
        try await wait { model.hasFinishedListeningPass && !controller.isPlaying }
        let selected = model.questionSelection

        model.replaySentence()
        try await wait { controller.isPlaying && (3_000..<4_900).contains(controller.confirmedMilliseconds) }
        try await wait { model.hasFinishedListeningPass && !controller.isPlaying }

        model.togglePlayback()
        try await wait { controller.isPlaying && model.displayedEnglishText.contains("last test sentence") }
        XCTAssertFalse(model.hasFinishedListeningPass)
        XCTAssertEqual(model.questionSelection, selected)
        model.togglePlayback()
        XCTAssertFalse(controller.isPlaying)

        model.step(by: -1)
        try await wait { model.hasFinishedListeningPass && !controller.isPlaying }
        XCTAssertTrue(model.displayedEnglishText.contains("third test sentence"))
        let firstCue = try XCTUnwrap(model.englishCues.first)
        model.selectTranscriptCue(firstCue)
        XCTAssertEqual(model.questionSelection?.reference.passage, original)
    }

    func testMKVKeepsLatestSentenceAndPreservesBlindListeningAcrossTheSameControls() async throws {
        let (model, suite) = try makeModel()
        let controller = model.playerController
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 192, height: 108),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let drawable = VLCVideoView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView = drawable
        defer { model.closeVideo(); window.orderOut(nil); suite.defaults.removePersistentDomain(forName: suite.name) }
        model.openVideo(try fixture("mkv"), seekTo: 1_000)
        try await wait { !model.isPreparingMedia }
        controller.attachVLCDrawable(drawable)
        model.loadSubtitle(try fixture("srt", name: "Playback.en"), language: .english)
        model.loadSubtitle(try fixture("srt", name: "Playback.zh"), language: .chinese)
        try await wait { controller.isPlaying && model.displayedEnglishText.contains("first test sentence") }
        controller.pause()
        model.seekPlayback(toMilliseconds: 7_500)
        XCTAssertEqual(controller.pendingSeekMilliseconds, 7_500)
        XCTAssertFalse(model.canAnalyzeCurrentSubtitle)

        model.togglePlayback()
        try await wait { controller.isPlaying && controller.pendingSeekMilliseconds == nil }
        model.step(by: -1)
        model.step(by: -1)
        model.step(by: 1)
        try await wait { model.hasFinishedListeningPass && !controller.isPlaying }
        XCTAssertTrue(model.displayedEnglishText.contains("third test sentence"))

        model.setListeningFirst(true)
        XCTAssertFalse(model.showEnglishSubtitle)
        XCTAssertNil(model.questionReference(currentOnly: true))
        try await wait { model.hasFinishedListeningPass && !controller.isPlaying }
        model.revealSubtitle()
        XCTAssertTrue(model.showEnglishSubtitle)
        XCTAssertFalse(model.showChineseSubtitle)
        try await wait { model.hasFinishedListeningPass && !controller.isPlaying }
        XCTAssertTrue(model.displayedEnglishText.contains("third test sentence"))
        model.pauseForModeSwitch()
        XCTAssertFalse(controller.isPlaying)

        let track = try XCTUnwrap(model.embeddedSubtitleTracks.first { $0.normalizedLanguageCode == "eng" })
        model.loadEmbeddedSubtitle(track, language: .english)
        try await wait { model.selectedEnglishEmbeddedTrackID == track.id }
        model.selectTranscriptCue(try XCTUnwrap(model.englishCues.first))
        let original = try XCTUnwrap(model.questionSelection?.reference)
        XCTAssertEqual(original.source?.videoTrack, .embedded(track.id))
        model.loadSubtitle(try fixture("srt", name: "Playback.zh"), language: .english)
        try await model.locateQuestionSource(original, excerpt: nil)
        XCTAssertEqual(model.selectedEnglishEmbeddedTrackID, track.id)
        XCTAssertTrue(model.englishCues.first?.text.contains("first test sentence") == true)
    }

    func testSavedVideoQuoteReopensItsFileAndSeeksToTheCueContainingTheQuote() async throws {
        let (model, suite) = try makeModel()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            model.closeVideo()
            suite.defaults.removePersistentDomain(forName: suite.name)
            try? FileManager.default.removeItem(at: directory)
        }
        let video = try fixture("mp4")
        let subtitles = directory.appending(path: "Custom.en.srt")
        try """
        1
        00:00:01,000 --> 00:00:02,900
        She looked up a word

        2
        00:00:03,000 --> 00:00:05,000
        in the dictionary.
        """.write(to: subtitles, atomically: true, encoding: .utf8)
        model.openVideo(video, seekTo: 1_100)
        try await wait { !model.isPreparingMedia }
        model.loadSubtitle(subtitles, language: .english)
        let first = try XCTUnwrap(model.englishCues.first)
        model.selectTranscriptCue(first)
        let reference = try XCTUnwrap(model.questionSelection?.reference)
        XCTAssertEqual(reference.passage, "She looked up a word in the dictionary.")
        let quote = try XCTUnwrap(reference.linkRange(for: "in the dictionary"))
        XCTAssertEqual(reference.source?.videoTrack, .external(subtitles))
        let different = try fixture("srt", name: "Playback.en")
        model.loadSubtitle(different, language: .english)
        try await model.locateQuestionSource(reference, excerpt: quote)
        XCTAssertEqual(model.englishCues.first?.text, "She looked up a word")
        model.closeVideo()
        try await model.locateQuestionSource(reference, excerpt: quote)
        let controller = model.playerController
        try await wait { controller.pendingSeekMilliseconds == nil }
        XCTAssertEqual(model.currentSourceVideoURL, video.standardizedFileURL)
        XCTAssertEqual(controller.currentMilliseconds, 3_000, accuracy: 100)
        XCTAssertFalse(controller.isPlaying)
        let other = directory.appending(path: "Other.mp4")
        try FileManager.default.copyItem(at: video, to: other)
        model.openVideo(other, seekTo: 1_000)
        try await wait { !model.isPreparingMedia && controller.pendingSeekMilliseconds == nil }
        try "1\n00:00:01,000 --> 00:00:02,900\nThe subtitle was edited.\n".write(to: subtitles, atomically: true, encoding: .utf8)
        do { try await model.locateQuestionSource(reference, excerpt: quote); XCTFail("Edited subtitle accepted") }
        catch { XCTAssertEqual(model.currentSourceVideoURL, other.standardizedFileURL) }
    }

    func testLegacyHistoryCopiesCommittedWALDataOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appending(path: "AEVP/library.sqlite3")
        let destinationURL = root.appending(path: "SmartRead/VideoStudy/videos.sqlite3")
        let original = try LearningRepository(databaseURL: originalURL)
        let media = try fixture("mkv")
        let record = try original.registerVideo(url: media, displayName: "Legacy video", durationMilliseconds: 10_000)
        try original.saveVideoState(.init(videoURL: media, displayName: "Legacy video",
                                          durationMilliseconds: 10_000, lastPositionMilliseconds: 8_000,
                                          totalWatchedMilliseconds: 4_000, playbackRate: 1.25, selectedAudioTrackID: 2,
                                          englishSubtitleKind: .embedded, englishSubtitlePath: nil, englishSubtitleTrackID: 5,
                                          chineseSubtitleKind: .automatic, chineseSubtitlePath: nil, chineseSubtitleTrackID: nil))
        XCTAssertTrue(try LearningRepository.importLegacyLibrary(from: originalURL, to: destinationURL))
        let destination = try LearningRepository(databaseURL: destinationURL)
        let imported = try XCTUnwrap(destination.videoRecord(for: media))
        XCTAssertEqual(imported.id, record.id)
        XCTAssertEqual(imported.lastPositionMilliseconds, 8_000)
        XCTAssertEqual(imported.playbackRate, 1.25)
        XCTAssertEqual(imported.englishSubtitleTrackID, 5)
        try destination.saveVideoState(.init(videoURL: media, displayName: "Legacy video",
                                             durationMilliseconds: 10_000, lastPositionMilliseconds: 9_000,
                                             totalWatchedMilliseconds: 5_000, playbackRate: 1.25, selectedAudioTrackID: 2,
                                             englishSubtitleKind: .embedded, englishSubtitlePath: nil, englishSubtitleTrackID: 5,
                                             chineseSubtitleKind: .automatic, chineseSubtitlePath: nil, chineseSubtitleTrackID: nil))
        XCTAssertFalse(try LearningRepository.importLegacyLibrary(from: originalURL, to: destinationURL))
        XCTAssertEqual(try destination.videoRecord(for: media)?.lastPositionMilliseconds, 9_000)
        XCTAssertEqual(try original.videoRecord(for: media)?.lastPositionMilliseconds, 8_000)
    }

    private func makeModel() throws -> (VideoStudyModel, (name: String, defaults: UserDefaults)) {
        let name = "SmartRead.VideoStudyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = VideoStudyModel(repository: try LearningRepository(inMemory: true), defaults: defaults)
        model.playerController.volume = 0
        return (model, (name, defaults))
    }

    private func fixture(_ ext: String, name: String = "Playback") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "VideoPlayback"))
    }

    private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The real video player did not reach the expected state", file: file, line: line)
        throw CocoaError(.fileReadUnknown)
    }
}
