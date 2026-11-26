import Foundation
import WebKit

@MainActor
struct ArticleImporter {
    private let session: URLSession

    init(session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 35
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()) { self.session = session }

    func webpage(_ value: String) async throws -> Article {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: address), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else {
            throw ReaderError.message("请输入完整的网页链接。")
        }

        let parser = try HTMLExtractor()
        let page: (text: String, url: URL, mimeType: String?)
        do {
            page = try await download(url)
        } catch {
            if !Task.isCancelled, isX(url), url.pathComponents.contains("status"),
               let post = try? await embeddedPost(url, parser: parser) {
                return try Article(title: post.title, body: post.body, sourceURL: url, byline: post.byline)
            }
            throw error
        }
        let mode = isX(page.url) ? "x" : "web"
        if page.mimeType == "text/plain" {
            return try Article(title: page.url.lastPathComponent, body: page.text, sourceURL: page.url)
        }
        if let result = try await parser.extract(page.text, url: page.url, mode: mode) {
            return try Article(title: result.title.isEmpty ? host : result.title, body: result.body,
                               sourceURL: url, byline: result.byline)
        }
        if mode == "x", page.url.pathComponents.contains("status") {
            if let post = try? await embeddedPost(page.url, parser: parser) {
                return try Article(title: post.title, body: post.body, sourceURL: url, byline: post.byline)
            }
        }
        throw ReaderError.message("没有提取到正文。请在浏览器打开原文，复制正文，再用「粘贴文本」导入。")
    }

    func textFile(_ url: URL, relativePath: String? = nil) throws -> Article {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw ReaderError.message("文件过大，请分段导入。") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw ReaderError.message("无法读取编码。请将文件存为 UTF-8，或直接粘贴文本。")
        }
        if let article = try LearningArticleInput.parse(text, relativePath: relativePath) { return article }
        return try Article(title: url.deletingPathExtension().lastPathComponent, body: text)
    }

    private func isX(_ url: URL) -> Bool {
        ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]
            .contains(url.host?.lowercased() ?? "")
    }

    private func download(_ url: URL) async throws -> (text: String, url: URL, mimeType: String?) {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.readResponse(request, session: session,
            types: ["text/html", "application/xhtml+xml", "text/plain"])
        let encoding = response.textEncodingName.map {
            let id = CFStringConvertIANACharSetNameToEncoding($0 as CFString)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(id))
        }
        let text = encoding.flatMap { String(data: data, encoding: $0) }
            ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        guard let text else { throw ReaderError.message("无法识别网页编码。请复制正文导入。") }
        return (text, response.url ?? url, response.mimeType)
    }

    nonisolated static func readResponse(_ request: URLRequest, session: URLSession, types: [String],
                                         limit: Int = 8_000_000) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse).map { "（HTTP \($0.statusCode)）" } ?? ""
            throw ReaderError.message("网页无法读取\(status)。可在浏览器打开后复制正文。")
        }
        guard response.mimeType.map(types.contains) ?? true else {
            throw ReaderError.message("这条链接指向的内容不是网页或纯文本。")
        }
        let tooLarge = ReaderError.message("网页超过 8 MB，请改用粘贴文本。")
        guard response.expectedContentLength <= Int64(limit) else { throw tooLarge }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw tooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private func embeddedPost(_ url: URL, parser: HTMLExtractor) async throws -> ExtractedArticle? {
        var components = URLComponents(string: "https://publish.twitter.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString),
                                 URLQueryItem(name: "omit_script", value: "true")]
        let (data, response) = try await Self.readResponse(URLRequest(url: components.url!), session: session, types: ["application/json", "text/javascript"])
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let embed = try? JSONDecoder().decode(XEmbed.self, from: data),
              let post = try await parser.extract(embed.html, url: url, mode: "x-embed") else { return nil }
        return ExtractedArticle(title: post.title, body: post.body, byline: embed.authorName)
    }

    private struct XEmbed: Decodable {
        let html: String
        let authorName: String
        enum CodingKeys: String, CodingKey { case html; case authorName = "author_name" }
    }
}

struct ExtractedArticle: Decodable {
    let title: String
    let body: String
    let byline: String?
}

@MainActor
final class HTMLExtractor: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private let script: String
    private var navigation: CheckedContinuation<Void, Error>?
    private var ready = false

    init(resourceBundle: Bundle? = nil) throws {
        let packageName = "SmartRead_SmartRead.bundle"
        let installed = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appending(path: packageName)) }
        let bundle = resourceBundle ?? installed ?? Bundle.module
        guard let readability = bundle.url(forResource: "Readability", withExtension: "js"),
              let extractor = bundle.url(forResource: "ExtractArticle", withExtension: "js") else {
            throw ReaderError.message("找不到网页提取组件，请重新构建 App。")
        }
        script = try String(contentsOf: readability, encoding: .utf8) + "\n"
            + String(contentsOf: extractor, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func extract(_ html: String, url: URL, mode: String) async throws -> ExtractedArticle? {
        if !ready {
            try await withCheckedThrowingContinuation { continuation in
                navigation = continuation
                view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            }
        }
        try Task.checkCancellation()
        let result = try await view.callAsyncJavaScript(
            script,
            arguments: ["html": html, "sourceURL": url.absoluteString, "mode": mode],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let fields = result as? [String: Any] else { return nil }
        return try JSONDecoder().decode(ExtractedArticle.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        self.navigation?.resume()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error)
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        navigation?.resume(throwing: ReaderError.message("网页提取组件已关闭。请重试导入。"))
        navigation = nil
    }
}
