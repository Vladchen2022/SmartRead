import Foundation
import XCTest
@testable import SmartRead

final class WebImportLimitTests: XCTestCase {
    private final class ResponseStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            var headers = ["Content-Type": "text/html"]
            if url.path == "/declared" { headers["Content-Length"] = "10000000" }
            if url.path == "/binary" { headers["Content-Type"] = "image/png" }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for _ in 0..<(url.path == "/stream" ? 5 : 4) {
                client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 16))
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testHeaderAndStreamLimitsAllowExactlyTheLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func load(_ path: String) async throws -> Data {
            let url = URL(string: "https://reader.invalid/" + path)!
            return try await ArticleImporter.readResponse(URLRequest(url: url), session: session, types: ["text/html"], limit: 64).0
        }
        let accepted = try await load("exact")
        XCTAssertEqual(accepted.count, 64)
        for path in ["declared", "stream", "binary"] {
            do { _ = try await load(path); XCTFail("Accepted \(path)") }
            catch let error as ReaderError {
                XCTAssertTrue(error.localizedDescription.contains(path == "binary" ? "网页或纯文本" : "8 MB"))
            }
        }
    }
}
