import SwiftUI

private struct SubtitleDriftControls: View {
    @ObservedObject var model: VideoStudyModel
    let language: SubtitleLanguage
    @State private var firstSource = 0.0
    @State private var firstVideo = 0.0
    @State private var secondSource = 0.0
    @State private var secondVideo = 0.0

    private func anchor(_ source: Double, _ video: Double) -> SubtitleTimingAnchor? {
        guard (0...360_000).contains(source), (0...360_000).contains(video) else { return nil }
        return SubtitleTimingAnchor(source: Int64((source * 1_000).rounded()), video: Int64((video * 1_000).rounded()))
    }

    private var preview: SubtitleTrackTiming? {
        guard let first = anchor(firstSource, firstVideo), let second = anchor(secondSource, secondVideo) else { return nil }
        return SubtitleTrackTiming(first: first, second: second)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language == .english ? "英文轨道" : "中文轨道").font(.headline)
            anchorRow("首点", source: $firstSource, video: $firstVideo)
            anchorRow("尾点", source: $secondSource, video: $secondVideo)
            Text("字幕时刻填原字幕秒数，画面时刻填同一句实际开口的秒数。两点相距至少 1 秒，建议在片头、片尾各选一句。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                let current = model.subtitleTiming(for: language)
                Text("当前倍率 \(current.scale, specifier: "%.5f")")
                if let preview { Text("预览：\(preview.scale, specifier: "%.5f")× · 起点偏移 \(Double(preview.offset) / 1000, specifier: "%+.3f") 秒") }
                Spacer()
                Button("应用双点") {
                    if let preview { model.applySubtitleTiming(preview, for: language) }
                }
                .disabled(preview == nil || (language == .english ? model.englishCues.isEmpty : model.chineseCues.isEmpty))
            }.font(.callout)
        }.padding(.vertical, 5)
    }

    private func anchorRow(_ title: String, source: Binding<Double>, video: Binding<Double>) -> some View {
        HStack {
            Text(title)
            TextField("字幕秒数", value: source, format: .number.precision(.fractionLength(0...3)))
                .accessibilityLabel("\(title)字幕秒数").frame(width: 92)
            Text("→")
            TextField("画面秒数", value: video, format: .number.precision(.fractionLength(0...3)))
                .accessibilityLabel("\(title)画面秒数").frame(width: 92)
            Button("取当前") {
                guard let point = model.subtitleAnchor(for: language) else { return }
                source.wrappedValue = Double(point.source) / 1_000
                video.wrappedValue = Double(point.video) / 1_000
            }.disabled(model.subtitleAnchor(for: language) == nil)
        }.textFieldStyle(.roundedBorder)
    }
}


struct VideoSubtitleCalibration: View {
    @ObservedObject var model: VideoStudyModel
    @Binding var isPresented: Bool

    var body: some View {
        Form {
            ForEach([SubtitleLanguage.english, .chinese], id: \.self) { language in
                Section {
                    LabeledContent("时间偏移（秒）") {
                        TextField("时间偏移", value: offset(for: language), format: .number.precision(.fractionLength(0...3)))
                            .labelsHidden()
                            .frame(width: 90)
                        Button("重置") { model.applySubtitleTiming(.init(), for: language) }
                    }
                    SubtitleDriftControls(model: model, language: language)
                }
                .disabled(language == .english ? model.englishCues.isEmpty : model.chineseCues.isEmpty)
            }
            Button("完成") { isPresented = false }
        }
        .formStyle(.grouped)
        .frame(width: 515, height: 460)
    }

    private func offset(for language: SubtitleLanguage) -> Binding<Double> {
        Binding(get: { Double(model.subtitleOffset(for: language)) / 1000 }, set: { seconds in
            guard (-60...60).contains(seconds) else { return }
            model.setSubtitleOffset(Int64((seconds * 1000).rounded()), for: language)
        })
    }
}

struct VideoStudySettings: View {
    @ObservedObject var model: VideoStudyModel

    var body: some View {
        Form {
            Section("字幕") {
                Picker("默认阅读方式", selection: Binding(get: { model.englishReadingMode }, set: model.setEnglishReadingMode)) {
                    ForEach(EnglishReadingMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Obsidian") {
                if !model.obsidianDestinationPath.isEmpty {
                    Text(model.obsidianDestinationPath).textSelection(.enabled)
                }
                HStack {
                    Button("选择笔记目录…") {
                        if let url = FilePanelService.chooseDirectory(title: "选择 Obsidian 笔记目录", prompt: "选择") {
                            model.setObsidianVault(url)
                        }
                    }
                    Button("重试已确认笔记", action: model.synchronizeDailyNotes)
                        .disabled(model.obsidianVaultPath.isEmpty)
                    Button("预览历史迁移…", action: model.previewNoteMigration)
                        .disabled(model.obsidianDestinationPath.isEmpty)
                    Button("停止写入", action: model.clearObsidianVault)
                        .disabled(model.obsidianVaultPath.isEmpty)
                }
                Text("查看结果后，点击视频助手的「添加到 Obsidian」保存。")
                    .foregroundStyle(ReaderPalette.muted)
                if !model.obsidianSyncStatus.isEmpty { Text(model.obsidianSyncStatus) }
                if let preview = model.noteMigrationPreview {
                    Text("将 \(preview.entries.count) 条已确认笔记写入 \(preview.destination)")
                    HStack {
                        Button("取消", action: model.cancelNoteMigration)
                        Button("确认迁移", action: model.confirmNoteMigration)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
