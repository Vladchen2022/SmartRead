import SwiftUI

struct SubtitleTranscriptView: View {
    @ObservedObject var model: VideoStudyModel
    @State private var followsPlayback = true
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        VStack(spacing: 10) {
            TextField("搜索英文或中文台词", text: $model.transcriptSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("transcriptSearch")
            HStack {
                Text("\(model.filteredTranscript.count) 条字幕")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("跟随播放", isOn: $followsPlayback).toggleStyle(.checkbox)
            }
            .font(.callout).padding(.horizontal, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.filteredTranscript) { cue in
                            Button { model.selectTranscriptCue(cue) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(SubtitleTimeLabel.string(model.videoTime(for: cue)))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(cue.text).font(.system(size: max(12, 16 * scale)))
                                        .fixedSize(horizontal: false, vertical: true)
                                    let chinese = model.chineseText(for: cue)
                                    if !chinese.isEmpty {
                                        Text(chinese).font(.system(size: max(11, 14 * scale)))
                                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(model.activeEnglish.contains(where: { $0.id == cue.id })
                                    ? ReaderPalette.accentFill : Color.primary.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(cue.id)
                            .help("暂停并跳转到 \(SubtitleTimeLabel.string(model.videoTime(for: cue)))")
                        }
                        if model.filteredTranscript.isEmpty {
                            Text(model.englishCues.isEmpty ? "请先加载英文字幕。" : "没有匹配的字幕。")
                                .foregroundStyle(.secondary).padding()
                        }
                    }.padding(.horizontal, 12)
                }
                .onAppear {
                    if let id = model.activeEnglish.first?.id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: model.activeEnglish.map(\.id)) { _, ids in
                    guard followsPlayback, model.transcriptSearch.isEmpty, let id = ids.first else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            Text("点击台词暂停并跳转；原字幕分块保留，不强行配成一一对应的双语句子。")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.padding(.top, 10)
    }
}
