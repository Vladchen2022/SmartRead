import Observation
import SmartReadSync
import SwiftUI

struct ListeningTarget {
    let reference: AssistantQuestionReference
    var milliseconds: Int64?
}

struct TextListeningMark: Equatable {
    let id: UUID
    let range: NSRange

    static func matching(_ marks: [Self], selection: NSRange?, click: Int?) -> Self? {
        if let selection {
            let first = marks.first { NSIntersectionRange($0.range, selection).length > 0 }
            guard let first, !marks.contains(where: {
                $0.id != first.id && NSIntersectionRange($0.range, selection).length > 0
            }) else { return nil }
            return first
        }
        guard let click else { return nil }
        return marks.first { NSLocationInRange(click, $0.range) }
    }
}

struct ListeningMark: Codable, Identifiable {
    let id: UUID
    let source: AssistantQuestionSource
    let passage: String
    let milliseconds: Int64?
    var manuallyMarked: Bool?
    var replayCount: Int?
    var slowReplayCount: Int?
    var reviewedReplayCount: Int?
    var reviewedSlowCount: Int?
    var isSaved: Bool?

    var isMarked: Bool { manuallyMarked ?? true }
    var replays: Int { replayCount ?? 0 }
    var slowReplays: Int { slowReplayCount ?? 0 }
    var reviewedSlowPlays: Int { reviewedSlowCount ?? min(slowReplays, reviewedReplayCount ?? 0) }
    var isSuggested: Bool {
        replays - (reviewedReplayCount ?? 0) >= 2 || (source.mode == .text && slowReplays > reviewedSlowPlays)
    }
    var needsReview: Bool { isMarked || isSuggested }

    var reference: AssistantQuestionReference {
        AssistantQuestionReference(passage: passage, source: source)
    }

    var materialID: String {
        if case let .text(_, _, pdf?) = source.location { return "book:\(pdf.book.id)" }
        return source.materialID
    }

    var pageIndex: Int {
        if case let .text(_, range, pdf?) = source.location { return pdf.sourcePage(at: range.location) }
        return 0
    }

    private var position: Int64 {
        if case let .text(_, range, _) = source.location { return Int64(range.location) }
        if case let .video(_, cues) = source.location { return cues.first?.start ?? 0 }
        return milliseconds ?? 0
    }

    var locationLabel: String? {
        if case .text(_, _, _?) = source.location { return "PDF 第 \(pageIndex + 1) 页" }
        return milliseconds.map(SubtitleTimeLabel.string)
    }

    func isSameSentence(as other: Self) -> Bool {
        guard source.mode == other.source.mode, source.materialID == other.source.materialID,
              source.positionID == other.source.positionID, source.videoTrack == other.source.videoTrack else { return false }
        return source.mode == .audio || passage.utf8.elementsEqual(other.passage.utf8)
    }

    func matches(_ cue: SubtitleCue, track: AssistantQuestionSource.VideoTrack?) -> Bool {
        guard source.videoTrack == track, case let .video(_, cues) = source.location else { return false }
        return cues.contains { $0.start == cue.startMilliseconds && $0.text.utf8.elementsEqual(cue.text.utf8) }
    }

    func precedes(_ other: Self) -> Bool {
        (pageIndex, position) < (other.pageIndex, other.position)
    }
}

@MainActor
@Observable
final class ListeningMarks {
    enum TextChange { case mark, slow, review }
    @ObservationIgnored var onTextChange: ((ListeningMark, TextChange) -> Void)?

    private let file: URL
    private var entries: [ListeningMark] = []
    private(set) var issue: String?
    private var loadFailed = false

    init(file: URL) {
        self.file = file
        do {
            entries = try JSONDecoder().decode([ListeningMark].self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        } catch {
            loadFailed = true
            issue = "无法读取听力标记。\(error.localizedDescription)"
        }
    }

    func marks(for mode: ReaderMode, materialID: String?) -> [ListeningMark] {
        rows(for: mode, materialID: materialID).filter(\.isMarked)
    }

    func rows(for mode: ReaderMode, materialID: String?) -> [ListeningMark] {
        entries.filter { $0.source.mode == mode && $0.materialID == materialID }.sorted { $0.precedes($1) }
    }

    @discardableResult
    func add(_ reference: AssistantQuestionReference, milliseconds: Int64? = nil) -> Bool {
        guard let mark = makeEntry(.init(reference: reference, milliseconds: milliseconds)), !loadFailed else { return false }
        var next = entries
        if let index = next.firstIndex(where: { $0.isSameSentence(as: mark) }) {
            if next[index].isMarked { return true }
            next[index].manuallyMarked = true
        } else {
            var marked = mark
            marked.manuallyMarked = true
            next.append(marked)
        }
        guard save(next) else { return false }
        if let added = next.first(where: { $0.isSameSentence(as: mark) }), added.source.mode == .text {
            onTextChange?(added, .mark)
        }
        return true
    }

    func recordReplay(_ target: ListeningTarget, speed: PlaybackSpeed) {
        guard let mark = makeEntry(target) else { return }
        var next = entries
        let index = next.firstIndex { $0.isSameSentence(as: mark) } ?? next.endIndex
        if index == next.endIndex { next.append(mark) }
        next[index].replayCount = next[index].replays + 1
        if speed == .threeQuarters {
            next[index].reviewedSlowCount = next[index].reviewedSlowPlays
            next[index].slowReplayCount = next[index].slowReplays + 1
        }
        if save(next), speed == .threeQuarters, mark.source.mode == .text {
            onTextChange?(next[index], .slow)
        }
    }

    private func makeEntry(_ target: ListeningTarget) -> ListeningMark? {
        let reference = target.reference
        guard let source = reference.source, !reference.passage.isEmpty else { return nil }
        var origin = source
        if case let .text(material, range, location?) = source.location, let chapter = location.chapter {
            var pdf = location
            let page = location.sourcePage(at: range.location)
            pdf.chapter = PDFChapterReading(chapter: chapter.chapter, join: chapter.join,
                                            translation: "", anchors: [.init(page: page, offset: range.location)])
            origin = AssistantQuestionSource(title: source.title, location: .text(material: material, range: range, pdf: pdf))
        }
        return ListeningMark(id: UUID(), source: origin, passage: reference.passage,
                             milliseconds: target.milliseconds, manuallyMarked: false)
    }

    func remove(_ id: UUID) {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].manuallyMarked = false
        next[index].reviewedReplayCount = next[index].replays
        next[index].reviewedSlowCount = next[index].slowReplays
        if save(next), next[index].source.mode == .text { onTextChange?(next[index], .review) }
    }

    func syncTextRows(_ rows: [ReadingMark], article: Article, key: String) throws {
        var next = entries
        var changed = false
        for row in rows where row.anchor.matches(article.body) {
            let range = NSRange(location: row.anchor.offset, length: row.anchor.length)
            let source = AssistantQuestionSource(title: article.title, location: .text(material: key, range: range, pdf: article.pdfPage))
            let reference = AssistantQuestionReference(passage: row.anchor.quote, source: source)
            guard let candidate = makeEntry(.init(reference: reference)) else { continue }
            let index = next.firstIndex {
                $0.isSameSentence(as: candidate) ||
                ($0.source.mode == .text && $0.source.materialID == key &&
                 $0.source.positionID == source.positionID && $0.passage.hasPrefix(row.anchor.quote))
            }
            var mark = index.map { next[$0] } ?? candidate
            guard (index == nil && (row.manuallyMarked || row.slowCount > 0)) ||
                mark.isMarked != row.manuallyMarked || mark.slowReplays != row.slowCount ||
                mark.reviewedSlowPlays != row.reviewedCount else { continue }
            mark.manuallyMarked = row.manuallyMarked
            mark.slowReplayCount = row.slowCount
            mark.reviewedSlowCount = row.reviewedCount
            if !row.needsReview { mark.reviewedReplayCount = mark.replays }
            if let index { next[index] = mark }
            else { next.append(mark) }
            changed = true
        }
        if changed, !save(next) { throw ReaderError.message(issue ?? "无法同步听力标记。") }
    }

    func isMediaFavorite(_ target: ListeningTarget) -> Bool {
        guard let mark = makeEntry(target), mark.source.mode != .text else { return false }
        return entries.contains { $0.isSameSentence(as: mark) && $0.isSaved == true }
    }

    func toggleMediaFavorite(_ target: ListeningTarget) throws {
        guard var mark = makeEntry(target), mark.source.mode != .text else { return }
        if let existing = entries.first(where: { $0.isSameSentence(as: mark) }) {
            try toggleMediaFavorite(existing.id)
        } else {
            mark.isSaved = true
            guard save(entries + [mark]) else { throw ReaderError.message(issue ?? "无法更新原句收藏。") }
        }
    }

    func toggleMediaFavorite(_ id: UUID) throws {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].isSaved = next[index].isSaved != true
        guard save(next) else { throw ReaderError.message(issue ?? "无法更新原句收藏。") }
    }

    @discardableResult
    private func save(_ next: [ListeningMark]) -> Bool {
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            entries = next
            issue = nil
            return true
        } catch {
            issue = "无法保存听力标记。\(error.localizedDescription)"
            return false
        }
    }
}

struct ListeningMarkSheet: View {
    private enum Filter: String, CaseIterable {
        case review = "待复习", suggested = "可能卡住", saved = "已收藏"
    }

    let rows: [ListeningMark]
    let issue: String?
    let passage: (ListeningMark) -> String
    let location: (ListeningMark) -> String?
    let open: (ListeningMark, Bool) async throws -> Void
    let remove: (UUID) -> Void
    let isFavorite: (ListeningMark) -> Bool
    let toggleFavorite: (ListeningMark) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pending: Task<Void, Never>?
    @State private var error: String?
    @State private var filter: Filter = .review
    @State private var sortByReplays = false

    private var visibleRows: [ListeningMark] {
        let filtered = rows.filter { row in
            switch filter {
            case .review: row.isMarked || row.isSuggested
            case .suggested: row.isSuggested
            case .saved: isFavorite(row)
            }
        }
        guard sortByReplays else { return filtered }
        return filtered.sorted {
            $0.replays == $1.replays ? $0.precedes($1) : $0.replays > $1.replays
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("听力标记").font(.title2.bold())
                Text("\(visibleRows.count) 句").foregroundStyle(ReaderPalette.muted)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("显示", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
                Toggle("按重听次数排序", isOn: $sortByReplays)
                    .toggleStyle(.checkbox)
            }
            if let message = error ?? issue {
                Text(message).foregroundStyle(ReaderPalette.warning)
            }
            if visibleRows.isEmpty {
                ContentUnavailableView("没有\(filter.rawValue)的句子", systemImage: "bookmark",
                    description: filter == .review ? Text("播放时双按 ↓ 或按 M 标记。主动重听两次的句子也会出现在这里。") : nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 11) {
                        ForEach(visibleRows) { mark in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    if let label = location(mark) { Text(label).monospacedDigit() }
                                    if mark.isMarked { Text("手动标记") }
                                    if mark.isSuggested { Text("可能卡住") }
                                    Spacer()
                                    Text("重听 \(mark.replays) 次 · 慢速听过 \(mark.slowReplays) 次").monospacedDigit()
                                }
                                .font(.caption).foregroundStyle(ReaderPalette.muted)
                                Text(passage(mark)).font(.title3).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Button("定位") { review(mark, replay: false) }
                                    Button("重听") { review(mark, replay: true) }
                                    Spacer()
                                    if mark.isMarked || mark.isSuggested {
                                        Button("移出待复习") { remove(mark.id) }
                                    }
                                    Button {
                                        perform { try await toggleFavorite(mark) }
                                    } label: {
                                        Label(isFavorite(mark) ? "已收藏" : "收藏原句",
                                              systemImage: isFavorite(mark) ? "star.fill" : "star")
                                    }
                                    .accessibilityIdentifier("listeningFavorite-\(mark.id)")
                                }
                                .disabled(pending != nil)
                            }
                            .padding(12)
                            .background(ReaderPalette.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 620, height: 450)
        .background(ReaderPalette.panel)
        .onDisappear { pending?.cancel() }
    }

    private func review(_ mark: ListeningMark, replay: Bool) {
        perform {
            try await open(mark, replay)
            if !replay { dismiss() }
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        error = nil
        pending = Task {
            defer { pending = nil }
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
