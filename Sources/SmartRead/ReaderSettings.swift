import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ReaderInterfaceSize: Int, CaseIterable {
    case compact = 65
    case medium = 80
    case large = 100
    case extraLarge = 115

    var scale: CGFloat { CGFloat(rawValue) / 100 }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .medium: "中号"
        case .large: "大号"
        case .extraLarge: "特大"
        }
    }
}

private struct ReaderInterfaceScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var readerInterfaceScale: CGFloat {
        get { self[ReaderInterfaceScaleKey.self] }
        set { self[ReaderInterfaceScaleKey.self] = newValue }
    }
}

struct ReaderPreferences: DynamicProperty {
    static let fontSizeKey = "bodyFontSize"
    static let maskRange = 0.0...0.95

    @AppStorage(Self.fontSizeKey) var fontSize = ReadingFontSize.defaultValue
    @AppStorage("readerInterfaceSize") var interfaceSize = ReaderInterfaceSize.large
    @AppStorage("articleWidthPreference") var bodyWidth = ReaderPaneLayout.defaultBodyWidth
    @AppStorage("inspectorWidthFraction") var inspectorFraction = ReaderPaneLayout.defaultInspectorFraction
    @AppStorage("showsReaderToolbarSliders") var showsToolbarSliders = true
    @AppStorage("clickWholeSentence") var clickWholeSentence = false
    @AppStorage("listeningMaskOpacity") var listeningMaskOpacity = 0.7
    @AppStorage("highlightsSpokenSentence") var highlightsSpokenSentence = true
    @AppStorage("listeningMarkSound") var listeningMarkSound = true

    func restoreLayout() {
        interfaceSize = .large
        fontSize = ReadingFontSize.defaultValue
        bodyWidth = ReaderPaneLayout.defaultBodyWidth
        inspectorFraction = ReaderPaneLayout.defaultInspectorFraction
        showsToolbarSliders = true
    }
}

struct ReaderSettings: View {
    @State private var pendingFolder: URL?
    let reader: ReaderModel
    let speech: ReaderSpeech
    let video: VideoStudyModel
    @State private var tab: Tab = .reading
    @State private var choosesSyncFolder = false
    @State private var sharesPDF = false
    @AppStorage(ReaderTheme.preferenceKey) private var theme: ReaderTheme = .white
    private var preferences = ReaderPreferences()

    private enum Tab: Hashable {
        case reading, listening, sync, video, model
    }

    var body: some View {
        TabView(selection: $tab) {
            reading
                .tabItem { Label("界面与阅读", systemImage: "textformat.size") }
                .tag(Tab.reading)
            listening
                .tabItem { Label("听读", systemImage: "speaker.wave.2") }
                .tag(Tab.listening)
            textSync
                .tabItem { Label("设备同步", systemImage: "arrow.trianglehead.clockwise") }
                .tag(Tab.sync)
            VideoStudySettings(model: video)
                .tabItem { Label("视频精学", systemImage: "play.rectangle") }
                .tag(Tab.video)
            ModelSettings(reader: reader)
                .tabItem { Label("LM Studio", systemImage: "desktopcomputer") }
                .tag(Tab.model)
        }
        .frame(width: 620, height: 475)
        .scrollContentBackground(.hidden)
        .background(ReaderPalette.dialog)
        .onChange(of: theme) { _, selected in selected.apply() }
    }

    private var textSync: some View {
        Form {
            Section("同步文件夹") {
                Button(reader.textSync.folderName ?? "选择 iCloud Drive 文件夹", systemImage: "folder") {
                    choosesSyncFolder = true
                }
                .accessibilityIdentifier("chooseSyncFolder")
                Text("在 iPhone 和 iPad 上选择同一个文件夹。选择后，文本阅读资料会自动同步。")
                    .foregroundStyle(.secondary)
                if reader.textSync.folderName != nil {
                    Button("立即同步") { Task { await reader.syncTextLibrary(force: true) } }
                        .disabled(reader.textSync.isSyncing)
                    if let date = reader.textSync.lastSync {
                        LabeledContent("上次检查", value: date.formatted(date: .omitted, time: .shortened))
                    }
                    if let material = reader.remoteReadingMaterial {
                        Button("继续读《\(material.displayTitle)》") { reader.openRemoteReadingMaterial() }
                    }
                    if reader.article.pdfPage != nil {
                        Button(sharesPDF ? "正在提取章节…" : "同步当前 PDF 的全部章节") {
                            sharesPDF = true
                            Task {
                                await reader.shareCurrentPDFChapters()
                                sharesPDF = false
                            }
                        }.disabled(sharesPDF)
                    }
                }
                if let message = reader.textSyncIssue ?? reader.textSync.error {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosesSyncFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { Task { await reader.connectTextSync(to: folder) } }
        }
    }

    private var reading: some View {
        Form {
            Section("界面") {
                Picker("主题配色", selection: $theme) {
                    ForEach(ReaderTheme.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settingsTheme")

                Picker("界面比例", selection: preferences.$interfaceSize) {
                    ForEach(ReaderInterfaceSize.allCases, id: \.self) { size in
                        Text("\(size.title) \(size.rawValue)%").tag(size)
                    }
                }
                .accessibilityIdentifier("settingsInterfaceSize")
                .help("缩放工具栏、操作按钮、选区浮窗和播放器")

                Toggle("在顶栏显示字号", isOn: preferences.$showsToolbarSliders)
                    .accessibilityIdentifier("settingsToolbarSliders")
            }
            Section("阅读布局") {
                LabeledContent("阅读字号") {
                    HStack(spacing: 10) {
                        Slider(value: preferences.$fontSize, in: ReadingFontSize.range, step: 1) {
                            Text("阅读字号")
                        }
                        .labelsHidden()
                        .accessibilityValue("\(Int(preferences.fontSize)) 磅")
                        .accessibilityIdentifier("settingsReadingFont")
                        Text("\(Int(preferences.fontSize)) 磅")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }

                widthSlider("正文宽度", value: preferences.$bodyWidth, in: 0...1, id: "settingsBodyWidth")
                widthSlider("阅读助手宽度", value: preferences.$inspectorFraction,
                            in: ReaderPaneLayout.inspectorFractionRange, id: "settingsInspectorWidth")
            }
            Section("阅读操作") {
                Picker("单击正文时", selection: preferences.$clickWholeSentence) {
                    Text("查词").tag(false)
                    Text("翻译整句").tag(true)
                }
                .accessibilityIdentifier("settingsClickMode")
            }
            Button("恢复默认布局", action: preferences.restoreLayout)
                .accessibilityIdentifier("settingsResetLayout")
            weeklyFavorites
        }
        .formStyle(.grouped)
    }

    private var weeklyFavorites: some View {
        let sync = reader.weeklyFavorites
        return Section("Obsidian 泛读收藏") {
            LabeledContent("保存目录") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(sync.folder?.lastPathComponent ?? "未设置")
                        .accessibilityIdentifier("weeklyFavoritesFolder")
                    if let parent = sync.folder?.deletingLastPathComponent().path {
                        Text((parent as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(parent)
                    }
                }
            }
            HStack {
                Button(sync.folder == nil ? "选择目录…" : "更换目录…") {
                    if let folder = FilePanelService.chooseDirectory(title: "选择 Obsidian 泛读收藏目录",
                                                                     prompt: "选择", initialDirectory: sync.folder) {
                        if sync.pendingCount > 0 && folder.standardizedFileURL != sync.folder?.standardizedFileURL {
                            pendingFolder = folder
                        } else { sync.setFolder(folder) }
                    }
                }
                .disabled(sync.isWorking)
                .accessibilityIdentifier("chooseWeeklyFavoritesFolder")
                if let folder = sync.folder {
                    Button("打开目录") { NSWorkspace.shared.open(folder) }
                    .accessibilityIdentifier("openWeeklyFavoritesFolder")
                }
            }
            Toggle("自动写入新收藏", isOn: Binding(get: { sync.automatic }, set: sync.setAutomatic))
                .disabled(sync.folder == nil)
                .accessibilityIdentifier("automaticWeeklyFavorites")
            HStack {
                Button("补写本周已有收藏", action: reader.backfillWeeklyFavorites)
                    .disabled(sync.folder == nil || sync.isWorking)
                    .accessibilityIdentifier("backfillWeeklyFavorites")
                Spacer()
                Text("待写入 \(sync.pendingCount) 条")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyFavoritesPending")
                Button("重试", action: sync.retry)
                    .disabled(sync.pendingCount == 0 || sync.isWorking)
                    .accessibilityIdentifier("retryWeeklyFavorites")
            }
            if let status = sync.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weeklyFavoritesStatus")
            }
            if sync.hasPreviousDestination {
                Text("有 \(sync.previousDestinationCount) 条收藏仍待写入原目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("将这些收藏改写到当前目录") {
                    if let folder = sync.folder { sync.setFolder(folder, movingPending: true) }
                }.disabled(sync.isWorking)
            }
        }
        .confirmationDialog("待写入的 \(sync.pendingCount) 条收藏要保存在哪里？", isPresented: Binding(
            get: { pendingFolder != nil }, set: { if !$0 { pendingFolder = nil } }
        ), presenting: pendingFolder) { folder in
            Button("一并改写到新目录") { sync.setFolder(folder, movingPending: true) }
            Button("保留原来的写入目录") { sync.setFolder(folder) }
            Button("取消", role: .cancel) { }
        }
    }

    private var listening: some View {
        Form {
            Section("语音") {
                SpeechOutputOptions(speech: speech)
                    .pickerStyle(.menu)
            }
            Section("听力标记") {
                Toggle("标记成功时播放提示音", isOn: preferences.$listeningMarkSound)
                    .accessibilityIdentifier("settingsListeningMarkSound")
            }
            Section("播放时的正文") {
                Toggle("用黄色标出当前朗读句", isOn: preferences.$highlightsSpokenSentence)
                    .accessibilityIdentifier("settingsSpeechHighlight")
                LabeledContent("听读遮罩") {
                    HStack(spacing: 10) {
                        Slider(value: preferences.$listeningMaskOpacity, in: ReaderPreferences.maskRange, step: 0.05) {
                            Text("听读遮罩深浅")
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("settingsSpeechMask")
                        .help("调到 0% 关闭遮罩")
                        Text("\(Int((preferences.listeningMaskOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func widthSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                             id: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("窄").font(.caption).accessibilityHidden(true)
                Slider(value: value, in: range) {
                    Text(title)
                }
                .labelsHidden()
                .accessibilityIdentifier(id)
                Text("宽").font(.caption).accessibilityHidden(true)
            }
        }
    }
}

private struct ModelSettings: View {
    let reader: ReaderModel
    @State private var address = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section("本机服务器") {
                LabeledContent("地址") {
                    HStack(spacing: 10) {
                        TextField("本机服务器地址", text: $address, prompt: Text(LMStudioClient.defaultEndpoint))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("settingsServerAddress")
                            .onSubmit(connect)
                        Button("测试连接", action: connect)
                            .disabled(checking)
                            .accessibilityIdentifier("settingsTestConnection")
                    }
                }

                switch reader.connection {
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取模型列表…").foregroundStyle(.secondary)
                    }
                case .connected:
                    Label("已连接 · \(reader.models.count) 个模型", systemImage: "checkmark.circle")
                        .foregroundStyle(ReaderPalette.accent)
                case .unavailable(let reason):
                    Label(reason, systemImage: "exclamationmark.circle")
                        .foregroundStyle(ReaderPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !reader.models.isEmpty {
                    @Bindable var model = reader
                    Picker("模型", selection: $model.preferredModel) {
                        Text("自动选择第一个模型").tag("")
                        if !reader.preferredModel.isEmpty, !reader.models.contains(reader.preferredModel) {
                            Text("上次选择（当前不可用）").tag(reader.preferredModel)
                        }
                        ForEach(reader.models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { address = reader.endpoint }
    }

    private var checking: Bool {
        if case .checking = reader.connection { return true }
        return false
    }

    private func connect() {
        guard !checking else { return }
        task?.cancel()
        task = Task {
            await reader.connect(to: address)
            if case .connected = reader.connection { address = reader.endpoint }
        }
    }
}
