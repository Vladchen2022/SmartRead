import SwiftUI
import XCTest
@testable import SmartRead

final class SpeechTests: XCTestCase {
    @MainActor
    func testKokoroManualRequestCanInterruptBackgroundGeneration() async throws {
        guard KokoroEngine.isInstalled else { throw XCTSkip("本机未安装 Kokoro。") }
        let engine = KokoroEngine()
        try await engine.prepare()
        let prefetch = Task {
            try await engine.audio(for: String(repeating: "This is a longer background sentence. ", count: 16), voice: "am_adam")
        }
        try await Task.sleep(for: .milliseconds(120))
        prefetch.cancel()
        do { _ = try await prefetch.value; XCTFail("Prefetch finished after cancellation") }
        catch is CancellationError {}
        let foreground = try await engine.audio(for: "Read this sentence now.", voice: "am_adam")
        XCTAssertTrue(foreground.starts(with: Data("RIFF".utf8)))
        let cached = try await engine.audio(for: "Read this sentence now.", voice: "am_adam")
        XCTAssertEqual(cached, foreground)
    }

    @MainActor
    func testSpeechMenuScalesWithTheReaderInterface() {
        let speech = ReaderSpeech()
        func size(_ setting: ReaderInterfaceSize) -> CGSize {
            let menu = SpeechMenu(speech: speech, selection: nil, playArticle: { _ in }, playSelection: { _ in })
                .environment(\.readerInterfaceScale, setting.scale)
            return NSHostingView(rootView: menu).fittingSize
        }

        let compact = size(.compact)
        let extraLarge = size(.extraLarge)
        XCTAssertGreaterThan(compact.height, 0)
        XCTAssertGreaterThan(extraLarge.height, compact.height * 1.6)
        XCTAssertGreaterThan(extraLarge.width, compact.width * 1.6)
    }

    @MainActor
    func testPlaybackShortcutsMatchOnlyUnmodifiedPlaybackKeys() throws {
        func event(_ key: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: 0, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
        }

        XCTAssertEqual(PlaybackShortcut(event: try event(" ")), .toggle)
        XCTAssertEqual(PlaybackShortcut(event: try event("\u{F702}", modifiers: [.numericPad, .function])), .previous)
        XCTAssertEqual(PlaybackShortcut(event: try event("\u{F703}", modifiers: [.numericPad, .function])), .next)
        XCTAssertEqual(PlaybackShortcut(event: try event("\u{F701}", modifiers: [.numericPad, .function])), .replay)
        XCTAssertEqual(PlaybackShortcut(event: try event("\u{F700}", modifiers: [.numericPad, .function])), .toggleSpeed)
        XCTAssertNil(PlaybackShortcut(event: try event("\u{F700}", modifiers: [.command, .function])))
        XCTAssertNil(PlaybackShortcut(event: try event("\u{F701}", modifiers: [.command, .function])))
        XCTAssertNil(PlaybackShortcut(event: try event("\u{F701}", modifiers: [.shift, .function])))
        XCTAssertNil(PlaybackShortcut(event: try event("r")))
        XCTAssertNil(PlaybackShortcut(event: try event("s")))
        XCTAssertNil(PlaybackShortcut(event: try event("s", modifiers: .command)))
        XCTAssertNil(PlaybackShortcut(event: try event(" ", modifiers: .shift)))
        XCTAssertNil(PlaybackShortcut(event: try event("a")))
        XCTAssertEqual(PlaybackShortcut(event: try event("m")), .markListening)
        XCTAssertNil(PlaybackShortcut(event: try event("m", modifiers: .command)))
    }

    @MainActor
    func testSpeedButtonScalesWithTheReaderInterface() {
        func size(_ setting: ReaderInterfaceSize) -> CGSize {
            let menu = PlaybackSpeedMenu(selection: .constant(.normal), id: "testSpeed", help: "调整倍速")
                .environment(\.readerInterfaceScale, setting.scale)
            return NSHostingView(rootView: menu).fittingSize
        }

        let compact = size(.compact)
        let extraLarge = size(.extraLarge)
        XCTAssertGreaterThan(compact.height, 0)
        XCTAssertGreaterThan(extraLarge.height, compact.height * 1.6)
        XCTAssertGreaterThan(extraLarge.width, compact.width * 1.6)
    }

    @MainActor
    func testSpeedCanBeSetBeforeStartingAtAnySentence() throws {
        let suite = "SmartReadTests.Speech.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = ReaderSpeech(defaults: defaults)

        speech.setPlaybackSpeed(.threeQuarters)
        XCTAssertEqual(speech.phase, .ready)
        XCTAssertNil(speech.current)
        XCTAssertNil(speech.focusRequest)

        let sentences = ReadingIndex("She paused. Then she spoke.").articleSentences()
        for start in sentences.indices {
            speech.start(sentences, at: start)
            XCTAssertEqual(speech.current?.text, sentences[start].text)
            XCTAssertEqual(speech.focusRequest?.range, sentences[start].range)
            XCTAssertEqual(speech.playbackSpeed, .threeQuarters)
            speech.stop()
        }
        XCTAssertEqual(ReaderSpeech(defaults: defaults).playbackSpeed, .threeQuarters)
    }

    @MainActor
    func testPlaybackSpeedPersistsIndependentlyWithoutResumingPausedSpeech() throws {
        let suite = "SmartReadTests.Speech.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Float(1.2), forKey: "audioPlaybackSpeed")
        let speech = ReaderSpeech(defaults: defaults)
        XCTAssertEqual(speech.playbackSpeed, .normal)

        let sentences = ReadingIndex("She paused. Then she spoke.").articleSentences()
        speech.start(sentences, at: 1)
        speech.move(-1)
        speech.pause()
        let focus = speech.focusRequest

        let menu = PlaybackSpeedMenu(
            selection: Binding(get: { speech.playbackSpeed }, set: speech.setPlaybackSpeed),
            id: "testSpeed", help: "调整倍速"
        )
        menu.toggleSpeed()

        XCTAssertEqual(speech.phase, .paused)
        XCTAssertEqual(speech.focusRequest, focus)
        XCTAssertEqual(speech.current?.text, sentences[0].text)
        XCTAssertTrue(speech.singleSentence)
        XCTAssertEqual(ReaderSpeech(defaults: defaults).playbackSpeed, .threeQuarters)
        XCTAssertEqual(defaults.float(forKey: "audioPlaybackSpeed"), 1.2)
        menu.toggleSpeed()
        XCTAssertEqual(speech.playbackSpeed, .normal)
        XCTAssertEqual(speech.phase, .paused)
        XCTAssertEqual(speech.current?.text, sentences[0].text)
    }

    func testSavedSpeedsConvergeOnTheTwoSupportedRates() {
        XCTAssertEqual(PlaybackSpeed.allCases, [.threeQuarters, .normal])
        XCTAssertEqual(PlaybackSpeed(savedRate: 0), .normal)
        XCTAssertEqual(PlaybackSpeed(savedRate: 0.5), .threeQuarters)
        XCTAssertEqual(PlaybackSpeed(savedRate: 0.75), .threeQuarters)
        XCTAssertEqual(PlaybackSpeed(savedRate: 1), .normal)
        XCTAssertEqual(PlaybackSpeed(savedRate: 1.2), .normal)
        XCTAssertEqual(PlaybackSpeed(savedRate: 2), .normal)
    }

    @MainActor
    func testPausingAndClosingRejectStaleFocusCallbacks() throws {
        let speech = ReaderSpeech()
        let sentences = ReadingIndex("She paused. Then she spoke.").articleSentences()
        speech.start(sentences, at: 1)
        speech.move(-1)
        let first = try XCTUnwrap(speech.focusRequest)
        XCTAssertEqual(speech.phase, .positioning)
        XCTAssertEqual(first.range, sentences[0].range)

        speech.toggle()
        speech.focusArrived(first.id)
        XCTAssertEqual(speech.phase, .paused)
        XCTAssertFalse(speech.singleSentence)
        XCTAssertEqual(speech.index, 0)

        speech.toggle()
        let resumed = try XCTUnwrap(speech.focusRequest)
        XCTAssertEqual(speech.phase, .positioning)
        XCTAssertNotEqual(resumed.id, first.id)
        XCTAssertEqual(resumed.range, first.range)
        speech.focusArrived(first.id)
        XCTAssertEqual(speech.phase, .positioning)

        speech.stop()
        speech.focusArrived(resumed.id)
        XCTAssertEqual(speech.phase, .ready)
        XCTAssertNil(speech.focusRequest)
        XCTAssertNil(speech.current)
    }

    @MainActor
    func testPreviewStartsWithoutAListeningFocusAndCanBeReplacedByNormalPlayback() throws {
        let suite = "SmartReadTests.Speech.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = ReaderSpeech(defaults: defaults)
        let sentences = ReadingIndex("She paused. Then she spoke.").articleSentences()
        speech.start(sentences, at: 1)
        let focus = try XCTUnwrap(speech.focusRequest)

        speech.preview(sentences[0])
        XCTAssertTrue(speech.isPreviewing)
        XCTAssertTrue(speech.isActive)
        XCTAssertNil(speech.focusRequest)
        XCTAssertNil(speech.current)
        XCTAssertNil(speech.lastSpoken)
        speech.focusArrived(focus.id)
        XCTAssertTrue(speech.isPreviewing)

        speech.start(sentences, at: 1)
        XCTAssertFalse(speech.isPreviewing)
        XCTAssertEqual(speech.focusRequest?.range, sentences[1].range)
        speech.preview(sentences[1])
        speech.pause()
        XCTAssertFalse(speech.isPreviewing)
        XCTAssertEqual(speech.phase, .ready)
        XCTAssertNil(speech.focusRequest)
    }

    @MainActor
    func testSentenceNavigationPlaysOneSentenceIncludingBeyondTheSelection() throws {
        let speech = ReaderSpeech()
        let sentences = ReadingIndex("She paused. Then she spoke. The room was quiet.").articleSentences()
        speech.start([sentences[0]], selectionContinuation: Array(sentences.dropFirst()))
        XCTAssertFalse(speech.singleSentence)
        XCTAssertTrue(speech.hasNext)

        speech.replay()
        XCTAssertEqual(speech.current?.range, sentences[0].range)
        XCTAssertEqual(speech.focusRequest?.range, sentences[0].range)
        XCTAssertTrue(speech.singleSentence)

        speech.move(1)
        XCTAssertEqual(speech.current?.range, sentences[1].range)
        XCTAssertEqual(speech.focusRequest?.range, sentences[1].range)
        XCTAssertTrue(speech.singleSentence)

        speech.move(-1)
        XCTAssertEqual(speech.current?.range, sentences[0].range)
        XCTAssertTrue(speech.singleSentence)
        XCTAssertFalse(speech.hasPrevious)

        speech.toggle()
        XCTAssertEqual(speech.phase, .paused)
        XCTAssertFalse(speech.singleSentence)
        speech.toggle()
        XCTAssertFalse(speech.singleSentence)
        XCTAssertEqual(speech.phase, .positioning)
    }
}
