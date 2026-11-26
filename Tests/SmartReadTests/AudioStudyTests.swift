import AVFoundation
import XCTest
@testable import SmartRead

final class AudioStudyTests: XCTestCase {
    func testMissingAudioCanBeRelinkedWithoutRewritingTranscriptForProgress() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Playback", withExtension: "mp4", subdirectory: "VideoPlayback"))
        let store = AudioStudyStore(root: root)
        var entry = try await store.add(source)
        entry.cues = [.init(start: 0, end: 1, text: "My edits.")]
        try store.save(entry)
        let directory = store.mediaURL(for: entry).deletingLastPathComponent()
        let record = directory.appending(path: "record.json")
        let before = try Data(contentsOf: record)
        entry.position = 1
        try store.saveProgress(entry)
        XCTAssertEqual(try Data(contentsOf: record), before)
        try FileManager.default.removeItem(at: store.mediaURL(for: entry))
        let broken = try XCTUnwrap(store.inventory().entries.first)
        XCTAssertEqual(broken.position, 1)
        let wrong = directory.appending(path: "wrong.mp4")
        try Data("wrong".utf8).write(to: wrong)
        do { try await store.relink(wrong, to: broken); XCTFail("Different media was accepted") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaURL(for: entry).path)) }
        try await store.relink(source, to: broken)
        XCTAssertEqual(try Data(contentsOf: store.mediaURL(for: broken)), try Data(contentsOf: source))
        XCTAssertEqual(try store.load().first?.cues, entry.cues)
        try Data("broken".utf8).write(to: record)
        XCTAssertEqual(try store.inventory().unreadable.map { $0.resolvingSymlinksInPath() }, [record.resolvingSymlinksInPath()])
    }

    func testSubtitleLookupUsesTheClickedOccurrenceAndNearbySentences() throws {
        let cue = AudioStudyCue(start: 1, end: 4, text: "Look up the word. 📖 Then look up another one.")
        let entry = AudioStudyEntry(id: UUID(), title: "Lesson", format: .mp3, duration: 6, cues: [
            AudioStudyCue(start: 0, end: 1, text: "Open the book."),
            cue,
            AudioStudyCue(start: 4, end: 6, text: "Close the book.")
        ])
        let position = (cue.text as NSString).range(of: "look", options: .backwards).location
        let selection = try XCTUnwrap(AudioSubtitleSelection(entry: entry, cueID: cue.id, at: position))
        XCTAssertEqual(selection.word?.range.location, position)
        XCTAssertEqual(selection.sentence.text, "📖 Then look up another one.")
        XCTAssertEqual(selection.surrounding?.previousSentence, "Look up the word.")
        XCTAssertEqual(selection.surrounding?.nextSentence, "Close the book.")
        let request = try XCTUnwrap(selection.phraseRequest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try request.input().utf8))
                                 as? [String: Any])
        XCTAssertEqual(json["markedSentence"] as? String, "📖 Then ⟦look⟧ up another one.")
        XCTAssertNil(AudioSubtitleSelection(entry: entry, cueID: cue.id, at: cue.text.utf16.count - 1))
        let phrase = SubtitleWord(text: "look up", range: NSRange(location: position, length: 7))
        let dragged = try XCTUnwrap(AudioSubtitleSelection(entry: entry, cueID: cue.id, target: phrase))
        XCTAssertEqual(dragged.word?.markedContext, "📖 Then ⟦look up⟧ another one.")
        let reference = try XCTUnwrap(dragged.questionReference(in: entry))
        XCTAssertEqual(reference.passage, "📖 Then look up another one.")
        XCTAssertEqual(reference.focus, "look up")
        XCTAssertEqual(reference.timestamp, "0:01")
        let current = try XCTUnwrap(AudioSubtitleSelection(entry: entry, cueID: cue.id))
        XCTAssertEqual(current.sentence.text, "Look up the word.")
        XCTAssertNil(current.word)
    }

    func testSplitTranscriptUsesTimeSpansAndKeepsUnalignedTextTogether() {
        let text = "I can play. I can't sing."
        let first = NSRange(location: 0, length: 11)
        let second = NSRange(location: 12, length: 13)
        let timing = [
            AudioStudyTranscript.TimedText(range: first, start: 5, end: 6),
            AudioStudyTranscript.TimedText(range: second, start: 7, end: 8)
        ]
        let cues = AudioStudyTranscript.cues(in: text, start: 5, end: 8, timing: timing)
        XCTAssertEqual(cues.map { $0.text.trimmingCharacters(in: .whitespaces) }, ["I can play.", "I can't sing."])
        XCTAssertEqual(cues.map(\.start), [5, 7])
        XCTAssertEqual(cues.map(\.end), [6, 8])
        XCTAssertEqual(AudioStudyTranscript.cues(in: text, start: 5, end: 8, timing: [timing[0]]).count, 1)
    }

    func testPlaybackRangesKeepSentencePaddingOutOfOtherCues() throws {
        let entry = AudioStudyEntry(id: UUID(), title: "Test", format: .mp3, duration: 3, cues: [
            AudioStudyCue(start: 0.2, end: 1, text: "First."),
            AudioStudyCue(start: 1.06, end: 2.2, text: "Second.")
        ])
        let first = try XCTUnwrap(entry.playbackRange(for: 0))
        let second = try XCTUnwrap(entry.playbackRange(for: 1))
        XCTAssertEqual(first.lowerBound, 0.12, accuracy: 0.001)
        XCTAssertEqual(first.upperBound, 1.06, accuracy: 0.001)
        XCTAssertEqual(second.lowerBound, 1, accuracy: 0.001)
        XCTAssertEqual(second.upperBound, 2.32, accuracy: 0.001)
        XCTAssertEqual(entry.nextPlayableCue(at: 1.03), 1)
        XCTAssertNil(entry.nextPlayableCue(at: 3))
    }

    @MainActor
    func testClassroomAudioWorkflowWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtures = [environment["SMARTREAD_TEST_MP3"], environment["SMARTREAD_TEST_MP4"]].compactMap { $0 }
        guard !fixtures.isEmpty else { throw XCTSkip("No local classroom audio fixture was provided") }
        guard AudioStudyTranscriber.isAvailable else { throw XCTSkip("本机转写不可用") }
        let root = FileManager.default.temporaryDirectory.appending(path: "smartread-audio-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioStudyStore(root: root)
        let player = AVPlayer()
        player.isMuted = true
        let suite = "SmartRead.AudioStudyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AudioStudyModel(store: store, player: player, defaults: defaults)
        XCTAssertEqual(model.playbackSpeed, .normal)
        XCTAssertEqual(player.defaultRate, 1)
        for (offset, fixture) in fixtures.enumerated() {
            model.importMedia(URL(fileURLWithPath: fixture))
            try await waitUntil { !model.isImporting && model.transcriptionStatus == nil }
            XCTAssertNil(model.issue)
            XCTAssertNil(model.transcriptionError)
            let can = try XCTUnwrap(model.cues.firstIndex { $0.text.localizedCaseInsensitiveContains("play the piano") })
            let cannot = try XCTUnwrap(model.cues.firstIndex { $0.text.localizedCaseInsensitiveContains("sing at all") })
            XCTAssertEqual(cannot, can + 1)
            let first = model.cues[can]
            let second = model.cues[cannot]
            model.setPlaybackSpeed(.half)
            XCTAssertEqual(player.rate, 0)
            model.playCue(first.id)
            XCTAssertEqual(model.questionSelection?.reference.passage, first.text)
            let original = try XCTUnwrap(model.questionSelection?.reference)
            try await waitUntil { player.rate == 0.5 && player.timeControlStatus == .playing }
            model.setPlaybackSpeed(.faster)
            XCTAssertEqual(player.rate, 1.2)
            try await waitUntil { model.waitingForNext }
            XCTAssertEqual(model.focusedCueID, first.id)
            XCTAssertTrue(model.canMoveCue(by: 1))
            XCTAssertFalse(model.isPlaying)

            model.setPlaybackSpeed(.threeQuarters)
            XCTAssertEqual(player.rate, 0)
            model.moveCue(by: 1)
            let selected = model.questionSelection
            XCTAssertEqual(selected?.reference.passage, second.text)
            try await waitUntil { player.rate == 0.75 && player.timeControlStatus == .playing }
            try await waitUntil { model.waitingForNext }
            XCTAssertEqual(model.focusedCueID, second.id)
            XCTAssertEqual(model.questionSelection, selected)
            XCTAssertFalse(model.isPlaying)

            model.replay()
            try await waitUntil { model.waitingForNext }
            XCTAssertEqual(model.focusedCueID, second.id)

            model.togglePlayback()
            XCTAssertTrue(model.isPlaying)
            XCTAssertFalse(model.waitingForNext)
            XCTAssertEqual(player.currentItem?.forwardPlaybackEndTime.isValid, false)
            let excerpt = try XCTUnwrap(original.linkRange(for: "play the piano"))
            try model.locateQuestionSource(original, excerpt: excerpt)
            XCTAssertFalse(model.isPlaying)
            XCTAssertEqual(model.focusedCueID, first.id)
            XCTAssertEqual(model.position, first.start, accuracy: 0.001)
            XCTAssertEqual(model.sourceJump?.cueID, first.id)
            XCTAssertEqual(model.questionSelection, selected)

            model.seek(to: max(first.start, second.start - 0.25))
            XCTAssertEqual(model.focusedCueID, first.id)
            model.togglePlayback()
            try await waitUntil { model.focusedCueID == second.id }
            XCTAssertEqual(model.questionSelection, selected)
            model.locateCue(first.id)

            var edited = second
            edited.text = "Edited subtitle"
            try model.editCue(edited)
            let stale = try XCTUnwrap(selected?.reference)
            XCTAssertThrowsError(try model.locateQuestionSource(stale, excerpt: nil))
            let saved = try XCTUnwrap(store.load().first)
            XCTAssertEqual(saved.id, model.entry?.id)
            XCTAssertEqual(saved.cues?[cannot].text, edited.text)
            XCTAssertEqual(saved.position, model.position, accuracy: 0.02)
            XCTAssertEqual(model.history.count, offset + 1)
        }

        let reopened = AudioStudyModel(store: store, defaults: defaults)
        reopened.restore()
        XCTAssertEqual(reopened.entry?.id, model.entry?.id)
        XCTAssertEqual(reopened.position, model.position, accuracy: 0.02)
        XCTAssertTrue(reopened.cues.contains { $0.text == "Edited subtitle" })
        XCTAssertNil(reopened.transcriptionStatus)
        XCTAssertEqual(reopened.playbackSpeed, .threeQuarters)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        guard condition() else { throw ReaderError.message("Timed out waiting for the audio study state.") }
    }
}
