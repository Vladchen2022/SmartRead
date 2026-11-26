import XCTest
@testable import SmartRead

final class BilingualSubtitleAlignmentTests: XCTestCase {
    private func cue(_ start: Int64, _ end: Int64, _ text: String) -> SubtitleCue {
        SubtitleCue(startMilliseconds: start, endMilliseconds: end, text: text)
    }

    func testFourEnglishFragmentsCollectAllShortChineseFragmentsNotJustMidpoints() throws {
        let english = [cue(1_000, 2_000, "I was going to tell you"), cue(2_100, 3_100, "that we should leave"),
                       cue(3_200, 4_200, "before the rain"), cue(4_300, 5_300, "starts.")]
        let chinese = [cue(1_000, 1_150, "我正要"), cue(1_200, 1_350, "告诉你"), cue(1_500, 3_000, "我们应该"),
                       cue(3_100, 4_250, "在下雨之前"), cue(4_300, 5_300, "离开。")]
        let group = try XCTUnwrap(SubtitleSentenceContext.groups(in: english).first)
        let alignment = BilingualSubtitleAlignment(groups: [group], chineseCues: chinese.reversed())
        XCTAssertEqual(alignment.cues(for: group), chinese)
        XCTAssertEqual(alignment.text(for: group), "我正要 告诉你 我们应该 在下雨之前 离开。")
        XCTAssertEqual(alignment.cues(forEnglishCues: english), chinese)
        XCTAssertEqual(alignment.cues(forEnglishCues: [english[0]]), Array(chinese.prefix(3)))
    }

    func testOneChineseCueAcrossFourEnglishFragmentsIsNotRepeated() throws {
        let english = [cue(1_000, 2_000, "She was"), cue(2_100, 3_000, "going to"),
                       cue(3_100, 4_000, "visit"), cue(4_100, 5_000, "her mother.")]
        let group = try XCTUnwrap(SubtitleSentenceContext.groups(in: english).first)
        let chinese = cue(1_000, 5_000, "她打算去看望母亲。")
        let alignment = BilingualSubtitleAlignment(groups: [group], chineseCues: [chinese, chinese])
        XCTAssertEqual(alignment.text(for: group), chinese.text)
        for fragment in english { XCTAssertEqual(alignment.cues(forEnglishCues: [fragment]), [chinese]) }
    }

    func testIdenticalTextAtDistinctSourceTimesIsPreserved() {
        let group = SubtitleSentenceContext(cues: [cue(1_000, 5_000, "No, no.")])
        let first = cue(1_000, 2_000, "不。"), second = cue(3_000, 4_000, "不。")
        let alignment = BilingualSubtitleAlignment(groups: [group], chineseCues: [first, second])
        XCTAssertEqual(alignment.cues(for: group), [first, second])
        XCTAssertEqual(alignment.text(for: group), "不。 不。")
    }

    func testBoundarySliverDoesNotImportPreviousSpeakerOrDuplicateNextTurn() throws {
        let english = [cue(64_732, 68_318, "They cared about Wayne and Fig."),
                       cue(68_360, 69_945, "MISSY: Sheldon, if you don't get in here,"),
                       cue(69_987, 72_406, "I'm gonna lick your toothbrush! Coming!"),
                       cue(72_447, 73_908, "That's my sister.")]
        let groups = SubtitleSentenceContext.groups(in: english)
        XCTAssertEqual(groups.map { $0.cues.count }, [1, 2, 1])
        let previous = cue(66_983, 68_777, "就是韦恩和无花果卷")
        let first = cue(68_860, 70_487, "谢尔顿 你再不进来")
        let second = cue(70_570, 71_988, "我就要舔你的牙刷了")
        let mixed = cue(72_072, 74_365, "-来了\n-那是我妹妹")
        let alignment = BilingualSubtitleAlignment(groups: groups, chineseCues: [previous, first, second, mixed])
        XCTAssertEqual(alignment.cues(for: groups[0]), [previous])
        XCTAssertEqual(alignment.cues(for: groups[1]), [first, second])
        XCTAssertEqual(alignment.cues(for: groups[2]), [mixed], "Do not invent per-line times or split the source dialogue")
    }

    func testOffsetsUseVideoTimeAndRecalibrationCanRemoveWrongMatches() {
        let group = SubtitleSentenceContext(cues: [cue(1_000, 2_000, "Hello.")])
        let chinese = cue(2_000, 3_000, "你好。")
        XCTAssertEqual(BilingualSubtitleAlignment(groups: [group], chineseCues: [chinese], englishOffset: 2_000, chineseOffset: 1_000).text(for: group), "你好。")
        XCTAssertTrue(BilingualSubtitleAlignment(groups: [group], chineseCues: [chinese], englishOffset: 0, chineseOffset: 0).text(for: group).isEmpty, "Touching interval boundaries are not overlap")
        XCTAssertTrue(BilingualSubtitleAlignment(groups: [group], chineseCues: [chinese], chineseOffset: 60_000).text(for: group).isEmpty)
    }

    func testCueInsideInternalEnglishGapStillBelongsToWholeSentence() throws {
        let english = [cue(1_000, 2_000, "She left"), cue(3_000, 4_000, "without a word.")]
        let group = try XCTUnwrap(SubtitleSentenceContext.groups(in: english).first)
        let chinese = cue(2_100, 2_900, "她一言不发地离开了。")
        let alignment = BilingualSubtitleAlignment(groups: [group], chineseCues: [chinese])
        XCTAssertEqual(alignment.text(for: group), chinese.text)
        XCTAssertEqual(alignment.cues(forEnglishCues: english), [chinese])
        XCTAssertTrue(alignment.cues(forEnglishCues: [english[0]]).isEmpty)
    }

    func testEqualOverlapUsesStableEarlierGroupAndMissingTranslationIsEmpty() {
        let first = SubtitleSentenceContext(cues: [cue(1_000, 2_000, "First.")])
        let second = SubtitleSentenceContext(cues: [cue(2_000, 3_000, "Second.")])
        let alignment = BilingualSubtitleAlignment(groups: [first, second], chineseCues: [cue(1_500, 2_500, "原文整块保留。"), cue(20_000, 21_000, "无关场景")])
        XCTAssertEqual(alignment.text(for: first), "原文整块保留。")
        XCTAssertTrue(alignment.text(for: second).isEmpty)
        XCTAssertTrue(BilingualSubtitleAlignment(groups: [first], chineseCues: []).text(for: first).isEmpty)
    }
}
