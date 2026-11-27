import SwiftUI

struct SubtitleBar: View {
    @ObservedObject var model: VideoStudyModel
    let fontSize: Double
    let availableHeight: CGFloat
    let clickWholeSentence: Bool
    var listeningMarks: [ListeningMark] = []

    var body: some View {
        ScrollView(.vertical) {
          VStack(spacing: 7) {
            if model.showEnglishSubtitle, !model.displayedEnglishText.isEmpty {
                ClickableSubtitleText(
                    text: model.displayedEnglishText,
                    fontSize: subtitleFontSize,
                    selectedWord: model.displayedSelectedWord,
                    segments: model.readingFrame?.segments ?? [],
                    contentIdentity: (model.readingFrame?.context.cues ?? model.activeEnglish).map { $0.id.uuidString }.joined(separator: ","),
                    listeningMarks: markedRanges,
                    onSelectionBegan: model.pauseForLearning,
                    onWordClick: { word, sentence in
                        guard sentence == model.displayedEnglishText,
                              SubtitleWordTokenizer.isValidTarget(word, in: sentence) else { return }
                        if clickWholeSentence, !word.text.contains(where: \.isWhitespace) {
                            model.translateCurrentSubtitle()
                        } else {
                            model.lookupDisplayedWord(word, in: sentence)
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .allowsHitTesting(model.canUseSubtitleAtPlaybackPosition)
            }

            if model.showChineseSubtitle, !model.displayedChineseText.isEmpty {
                Text(model.displayedChineseText)
                    .font(.system(size: chineseFontSize))
                    .foregroundStyle(ReaderPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("中文字幕")
                    .accessibilityValue(model.displayedChineseText)
            }

            if let notice = model.subtitleNotice {
                Text(notice)
                    .font(.system(size: noticeFontSize))
                    .foregroundStyle(ReaderPalette.warning)
            }
          }
        .frame(maxWidth: .infinity, minHeight: max(0, subtitleBarHeight - 40))
        .padding(.vertical, 10)
        }
        .frame(height: subtitleBarHeight)
        .padding(.horizontal, 28)
        .background(ReaderPalette.paper)
        .overlay(alignment: .top) {
            Divider()
        }
        .overlay(alignment: .topTrailing) {
            if model.isSentenceLoopEnabled {
                Label("单句循环", systemImage: "repeat.1")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ReaderPalette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        ReaderPalette.accentFill,
                        in: Capsule()
                    )
                    .padding(.top, 10)
            }
        }
    }

    private var subtitleFontSize: CGFloat {
        CGFloat(fontSize)
    }

    private var markedRanges: [NSRange] {
        guard !listeningMarks.isEmpty else { return [] }
        let track = model.currentEnglishTrack
        func isMarked(_ cue: SubtitleCue) -> Bool {
            listeningMarks.contains { $0.matches(cue, track: track) }
        }
        if let frame = model.readingFrame {
            return frame.segments.filter { isMarked($0.cue) }.map(\.range)
        }
        var offset = 0
        return model.activeEnglish.compactMap { cue in
            let length = cue.text.utf16.count
            defer { offset += length + 1 }
            return isMarked(cue) ? NSRange(location: offset, length: length) : nil
        }
    }

    private var chineseFontSize: CGFloat {
        max(17, subtitleFontSize * 0.8)
    }

    private var noticeFontSize: CGFloat {
        max(12, subtitleFontSize * 0.45)
    }

    private var subtitleBarHeight: CGFloat {
        min(availableHeight * 0.42, max(85, subtitleFontSize * (model.usesSentenceReading ? 4.5 : 3.7)))
    }
}
