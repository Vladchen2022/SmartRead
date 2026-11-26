import Foundation

struct LearningFavoriteEntry: Identifiable {
    let favorite: LearningFavorite
    let pdfSource: String?

    var id: String { favorite.id }
}

struct ImportedLearningRecords: Sendable {
    let root: URL

    func key(for article: Article) -> String {
        let body = LearningRecord.fingerprint(article.body)
        return LearningRecord.fingerprint("\(SavedReadingPosition.key(for: article)):\(body)")
    }

    func load(for article: Article) throws -> LearningRecord? {
        let url = file(for: article)
        do {
            let value = try LearningRecordStore.read(url)
            guard value.body.utf8.elementsEqual(article.body.utf8), value.sourceId == nil else {
                throw ReaderError.message("这条收藏记录与当前正文不匹配。")
            }
            return value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    func records(for book: PDFBook) throws -> [LearningRecord] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory(for: book), includingPropertiesForKeys: nil,
                                                               options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? LearningRecordStore.read($0) }
            .filter { $0.pdfPage?.book.id == book.id }
    }

    func save(_ record: LearningRecord, for article: Article) throws {
        try LearningRecordStore.write(record, to: file(for: article))
    }

    func favoriteRecordFiles() throws -> [URL] {
        func contents(_ directory: URL) throws -> [URL] {
            do {
                return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: .skipsHiddenFiles)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return []
            }
        }
        let books = try contents(root.appending(path: "Books", directoryHint: .isDirectory))
        return try (contents(directory(for: nil)) + books.flatMap(contents)).filter { $0.pathExtension == "json" }
    }

    func importLegacy(_ legacy: LearningRecord?, for article: Article) throws -> LearningRecord? {
        let existing = try load(for: article)
        guard existing?.importedLegacy != true else { return existing }
        let legacy = legacy.flatMap { $0.sourceId == nil ? $0 : nil }
        guard existing != nil || legacy != nil else { return nil }

        var next = existing ?? LearningRecord(article: article, now: .now)
        if let legacy {
            if next.reading == ReadingFeedback() { next.reading = legacy.reading }
            for favorite in legacy.favorites {
                let id = LearningFavorite.id(articleId: next.articleId, kind: favorite.kind,
                                             range: NSRange(location: favorite.range.location, length: favorite.range.length))
                guard !next.favorites.contains(where: { $0.id == id }) else { continue }
                next.favorites.append(.init(favoriteId: id, kind: favorite.kind, selectedText: favorite.selectedText,
                                            sentence: favorite.sentence, paragraph: favorite.paragraph, range: favorite.range,
                                            result: favorite.result, createdAt: favorite.createdAt, updatedAt: favorite.updatedAt,
                                            anchorText: favorite.anchorText))
            }
            _ = next.touch()
        }
        next.importedLegacy = true
        try save(next, for: article)
        return next
    }

    private func directory(for book: PDFBook?) -> URL {
        if let book {
            return root.appending(path: "Books/\(LearningRecord.fingerprint(book.id))", directoryHint: .isDirectory)
        }
        return root.appending(path: "Articles", directoryHint: .isDirectory)
    }

    func file(for article: Article) -> URL {
        directory(for: article.pdfPage?.book).appending(path: key(for: article) + ".json")
    }
}

extension LearningRecord {
    func pdfArticle() throws -> Article {
        guard let pdfPage else { throw ReaderError.message("这条收藏缺少原 PDF 的位置。") }
        return try Article(title: title, body: body, pdfPage: pdfPage)
    }
}
