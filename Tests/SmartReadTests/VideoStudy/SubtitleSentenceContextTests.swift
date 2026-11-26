import XCTest
@testable import SmartRead

final class SubtitleSentenceContextTests: XCTestCase {
    private func cues(_ texts: [String], gap: Int64 = 100) -> [SubtitleCue] {
        texts.enumerated().map { i, text in
            let start = Int64(i) * (2_000 + gap)
            return SubtitleCue(startMilliseconds: start, endMilliseconds: start + 2_000, text: text)
        }
    }

    func testFourCueSentenceCanBeSelectedFromEveryBlock() throws {
        let all = cues(["I was going to tell you", "that we should leave", "before the rain", "starts.", "Dinner is ready."])
        for i in 0..<4 {
            let context = try XCTUnwrap(SubtitleSentenceContext.build(in: all, selected: [all[i]]))
            XCTAssertEqual(context.cues.count, 4)
            XCTAssertEqual(context.english, "I was going to tell you that we should leave before the rain starts.")
        }
    }

    func testThreeCueSentenceAndCapitalizedContinuation() throws {
        let all = cues(["When I got home,", "I realized", "that I had lost my keys."])
        let context = try XCTUnwrap(SubtitleSentenceContext.build(in: all, selected: [all[1]]))
        XCTAssertEqual(context.cues, all)
    }

    func testDifferentNamedSpeakersNeverJoinEvenWhenGrammarCouldContinue() throws {
        let all = cues(["ALICE: I was hoping", "BOB: that you would stop talking."])
        for i in all.indices {
            XCTAssertEqual(SubtitleSentenceContext.build(in: all, selected: [all[i]])?.cues, [all[i]])
        }
    }

    func testRequestKeepsSpeakerMetadataAndExcludesAdjacentTurn() throws {
        let all = cues(["ALICE: I was hoping", "BOB: that you would stop talking."])
        let context = try XCTUnwrap(SubtitleSentenceContext.build(in: all, selected: [all[1]]))
        let request = AIAnalysisRequest(english: all[1].text, chinese: "", previousEnglish: all[0].text, nextEnglish: nil, sourceContext: context)
        XCTAssertEqual(request.contextualEnglish, "BOB: that you would stop talking.")
    }

    func testDialogueDashesAndMultipleSpeakersWithinOneCueAreBoundaries() {
        for text in ["- I was hoping", "– I was hoping", "— I was hoping", "ALICE: I was hoping\nBOB: No."] {
            let all = cues([text, "that you could help."])
            XCTAssertEqual(SubtitleSentenceContext.build(in: all, selected: [all[1]])?.cues, [all[1]])
        }
    }

    func testLongGapInterruptionTerminalPunctuationAndStageDirectionsStopExpansion() {
        for first in ["I was hoping.", "I was hoping!", "I was hoping?", "I was hoping--", "[door closes]", "(music)"] {
            let all = cues([first, "that you could help."])
            XCTAssertEqual(SubtitleSentenceContext.build(in: all, selected: [all[1]])?.cues, [all[1]], first)
        }
        let all = cues(["I was hoping", "that you could help."], gap: 5_000)
        XCTAssertEqual(SubtitleSentenceContext.build(in: all, selected: [all[1]])?.cues.count, 1)
    }

    func testSimultaneousCuesAndUnknownCapitalizedTurnsAreNotExpanded() {
        let all = cues(["I was hoping", "You should leave."])
        XCTAssertEqual(SubtitleSentenceContext.build(in: all, selected: [all[1]])?.cues, [all[1]])
        let overlap = SubtitleCue(startMilliseconds: 100, endMilliseconds: 1_000, text: "No!")
        XCTAssertEqual(SubtitleSentenceContext.build(in: [all[0], overlap], selected: [all[0], overlap])?.cues.count, 2)
    }
}
