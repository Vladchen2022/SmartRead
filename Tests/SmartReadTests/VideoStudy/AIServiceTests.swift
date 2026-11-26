import Foundation
import XCTest
@testable import SmartRead

final class AIRequestBudgetTests: XCTestCase {
    func testCombinedBudgetCancelsSlowWork() async throws {
        do {
            let _: Int = try await withAIRequestBudget(.milliseconds(30)) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
            XCTFail("A request exceeding its budget succeeded")
        } catch let error as AIServiceError {
            XCTAssertEqual(error, .requestTimedOut)
        }
    }
}

final class AIServiceTests: XCTestCase {
    private var session: URLSession!
    private var service: LMStudioService!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        service = LMStudioService(session: session)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        service = nil
        super.tearDown()
    }

    func testListsModels() async throws {
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            XCTAssertEqual(request.url?.path, "/v1/models")
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"data":[{"id":"qwen-test"},{"id":"llama-test"}]}"#.utf8)
            )
        }

        let models = try await service.listModels(
            baseURL: "http://127.0.0.1:1234/v1"
        )

        XCTAssertEqual(models, ["qwen-test", "llama-test"])
    }

    func testRejectsNonLocalAddressBeforeSendingRequest() async {
        do {
            _ = try await service.listModels(baseURL: "https://example.com/v1")
            XCTFail("Expected a local-address validation error")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .invalidBaseURL)
        }
    }

    func testParsesStructuredAnalysis() async throws {
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            let requestData = try XCTUnwrap(Self.bodyData(from: request))
            // Schema property order controls grammar-constrained generation.
            // Translate only after the English has actually been generated.
            let raw = String(decoding: requestData, as: UTF8.self)
            let englishField = try XCTUnwrap(raw.range(of: "\"exampleEnglish\":{"))
            let chineseField = try XCTUnwrap(raw.range(of: "\"exampleChinese\":{"))
            XCTAssertLessThan(englishField.lowerBound, chineseField.lowerBound)
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestData)
                    as? [String: Any]
            )
            XCTAssertEqual(body["reasoning_effort"] as? String, "none")
            XCTAssertEqual(body["max_tokens"] as? Int, 2_048)
            let responseFormat = try XCTUnwrap(
                body["response_format"] as? [String: Any]
            )
            let jsonSchema = try XCTUnwrap(
                responseFormat["json_schema"] as? [String: Any]
            )
            let schema = try XCTUnwrap(
                jsonSchema["schema"] as? [String: Any]
            )
            let properties = try XCTUnwrap(
                schema["properties"] as? [String: Any]
            )
            XCTAssertNil(properties["analyzedEnglish"], "The app supplies the original subtitle")
            for key in ["translationZh", "keyExpression", "expressionMeaningZh",
                        "usageNoteZh", "exampleEnglish", "exampleChinese"] {
                let field = try XCTUnwrap(properties[key] as? [String: Any])
                XCTAssertEqual(field["minLength"] as? Int, 1)
            }
            let similarExpressions = try XCTUnwrap(
                properties["similarExpressions"] as? [String: Any]
            )
            XCTAssertEqual(similarExpressions["minItems"] as? Int, 2)
            XCTAssertEqual(similarExpressions["maxItems"] as? Int, 2)

            return (
                Self.response(for: request, statusCode: 200),
                try Self.chatResponseData(analysis: Self.analysis)
            )
        }

        let result = try await service.analyze(
            request: Self.analysisRequest,
            baseURL: "http://localhost:1234/v1",
            modelID: "qwen-test"
        )

        XCTAssertEqual(result, Self.analysis)
    }

    func testRejectsAnalysisWithoutTwoSimilarExpressions() async {
        let incomplete = SentenceAnalysis(
            translationZh: "你最近在忙什么？",
            keyExpression: "what are you up to",
            expressionMeaningZh: "询问某人在做什么",
            usageNoteZh: "非正式口语。",
            exampleEnglish: "What are you up to tonight?",
            exampleChinese: "你今晚打算做什么？",
            similarExpressions: [
                SimilarExpression(
                    english: "What have you been doing?",
                    chinese: "你最近在做什么？"
                )
            ]
        )
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            return (
                Self.response(for: request, statusCode: 200),
                try Self.chatResponseData(analysis: incomplete)
            )
        }

        do {
            _ = try await service.analyze(
                request: Self.analysisRequest,
                baseURL: "http://127.0.0.1:1234/v1",
                modelID: "qwen-test"
            )
            XCTFail("Expected invalid analysis")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .invalidAnalysis)
        }
    }

    func testRetriesWithoutStructuredOutputAfterUnsupportedParameter() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            requestCount += 1
            if requestCount == 1 {
                return (
                    Self.response(for: request, statusCode: 400),
                    Data(#"{"error":{"message":"response_format unsupported"}}"#.utf8)
                )
            }

            return (
                Self.response(for: request, statusCode: 200),
                try Self.chatResponseData(analysis: Self.analysis)
            )
        }

        let result = try await service.analyze(
            request: Self.analysisRequest,
            baseURL: "http://127.0.0.1:1234/v1",
            modelID: "qwen-test"
        )

        XCTAssertEqual(result, Self.analysis)
        XCTAssertEqual(requestCount, 2)
    }

    func testPropagatesTimeout() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await service.listModels(baseURL: "http://127.0.0.1:1234/v1")
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .requestTimedOut)
        }
    }

    func testRetriesTruncatedReasoningWithLargerBudget() async throws {
        var budgets: [Int] = []
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            let body = try Self.requestBody(request)
            budgets.append(try XCTUnwrap(body["max_tokens"] as? Int))
            XCTAssertNotNil(body["response_format"])
            if budgets.count == 1 {
                return (
                    Self.response(for: request, statusCode: 200),
                    try Self.rawChatResponse(
                        content: "",
                        finishReason: "length"
                    )
                )
            }
            return (
                Self.response(for: request, statusCode: 200),
                try Self.chatResponseData(analysis: Self.analysis)
            )
        }

        let result = try await service.analyze(
            request: Self.analysisRequest,
            baseURL: "http://127.0.0.1:1234/v1",
            modelID: "qwen-test"
        )
        XCTAssertEqual(result, Self.analysis)
        XCTAssertEqual(budgets, [2_048, 4_096])
    }

    func testTruncationRetryIsBoundedAndReportedAccurately() async {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            requestCount += 1
            return (
                Self.response(for: request, statusCode: 200),
                try Self.rawChatResponse(content: "{\"translationZh\":", finishReason: "length")
            )
        }

        do {
            _ = try await service.analyze(
                request: Self.analysisRequest,
                baseURL: "http://127.0.0.1:1234/v1",
                modelID: "qwen-test"
            )
            XCTFail("Expected an output budget error")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .analysisTruncated)
        }
        XCTAssertEqual(requestCount, 2)
    }

    func testReasoningIsNeverUsedAsTheFinalAnswer() async throws {
        let reasoning = String(decoding: try JSONEncoder().encode(Self.analysis), as: UTF8.self)
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            return (
                Self.response(for: request, statusCode: 200),
                try Self.rawChatResponse(content: "", reasoning: reasoning)
            )
        }

        do {
            _ = try await service.analyze(
                request: Self.analysisRequest,
                baseURL: "http://127.0.0.1:1234/v1",
                modelID: "qwen-test"
            )
            XCTFail("Thinking must not be shown or saved as a completed analysis")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .reasoningOutputDetected)
        }
    }

    func testUnsupportedReasoningControlFailsWithoutSilentlyEnablingThinking() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["reasoning_effort"] as? String, "none")
            return (Self.response(for: request, statusCode: 400),
                    Data(#"{"error":{"message":"reasoning_effort unsupported for this model"}}"#.utf8))
        }
        do {
            _ = try await service.analyze(request: Self.analysisRequest,
                baseURL: "http://127.0.0.1:1234/v1", modelID: "legacy-model")
            XCTFail("Thinking must not be silently re-enabled")
        } catch { XCTAssertEqual(error as? AIServiceError, .reasoningControlUnsupported) }
        XCTAssertEqual(requestCount, 1)
    }

    func testReadsFinalJSONAfterClosedThinkingAndMarkdownFence() async throws {
        let content = String(decoding: try JSONEncoder().encode(Self.analysis), as: UTF8.self)
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            return (
                Self.response(for: request, statusCode: 200),
                try Self.rawChatResponse(content: "<think></think>\n```json\n\(content)\n```")
            )
        }

        let result = try await service.analyze(
            request: Self.analysisRequest,
            baseURL: "http://127.0.0.1:1234/v1",
            modelID: "qwen-test"
        )
        XCTAssertEqual(result, Self.analysis)
    }

    func testRejectsMalformedAnalysisJSON() async {
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            let envelope: [String: Any] = [
                "choices": [
                    ["message": ["content": "not json"]]
                ]
            ]
            return (
                Self.response(for: request, statusCode: 200),
                try JSONSerialization.data(withJSONObject: envelope)
            )
        }

        do {
            _ = try await service.analyze(
                request: Self.analysisRequest,
                baseURL: "http://127.0.0.1:1234/v1",
                modelID: "qwen-test"
            )
            XCTFail("Expected invalid analysis")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .invalidAnalysis)
        }
    }

    func testRepairsAnEmptyExampleOnceWithoutEnablingReasoning() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
            requestCount += 1
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["reasoning_effort"] as? String, "none")
            if requestCount == 1 {
                var incomplete = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.analysis))
                        as? [String: Any]
                )
                incomplete["exampleEnglish"] = ""
                incomplete["exampleChinese"] = ""
                return (
                    Self.response(for: request, statusCode: 200),
                    try Self.rawChatResponse(content: String(
                        decoding: JSONSerialization.data(withJSONObject: incomplete),
                        as: UTF8.self
                    ))
                )
            }
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertTrue(messages.last?["content"]?.contains("上次回复未通过") == true)
            return (
                Self.response(for: request, statusCode: 200),
                try Self.chatResponseData(analysis: Self.analysis)
            )
        }

        let result = try await service.analyze(
            request: Self.analysisRequest,
            baseURL: "http://127.0.0.1:1234/v1",
            modelID: "qwen-test"
        )
        XCTAssertEqual(result, Self.analysis)
        XCTAssertEqual(requestCount, 2)
    }

    func testRejectsEveryBlankRequiredFieldWithBoundedRepair() async throws {
        for key in ["translationZh", "keyExpression", "expressionMeaningZh",
                    "usageNoteZh", "exampleEnglish", "exampleChinese"] {
            var requestCount = 0
            var incomplete = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.analysis))
                    as? [String: Any]
            )
            incomplete[key] = " \n "
            let content = String(
                decoding: try JSONSerialization.data(withJSONObject: incomplete),
                as: UTF8.self
            )
            MockURLProtocol.handler = { request in
            if let review = try Self.reviewResponseIfNeeded(request) { return review }
                requestCount += 1
                return (
                    Self.response(for: request, statusCode: 200),
                    try Self.rawChatResponse(content: content)
                )
            }
            do {
                _ = try await service.analyze(
                    request: Self.analysisRequest,
                    baseURL: "http://127.0.0.1:1234/v1",
                    modelID: "qwen-test"
                )
                XCTFail("Expected an error for blank \(key)")
            } catch {
                XCTAssertEqual(error as? AIServiceError, .invalidAnalysis)
            }
            XCTAssertEqual(requestCount, 2)
        }
    }

    private static func reviewResponseIfNeeded(_ request: URLRequest) throws -> (HTTPURLResponse, Data)? {
        guard request.httpMethod == "POST" else { return nil }
        let body = try requestBody(request)
        let messages = body["messages"] as? [[String: String]]
        let system = messages?.first?["content"] ?? ""
        guard system.contains("严格核查英语学习材料") || system.contains("双语例句审校员") else { return nil }
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        let review = system.contains("双语例句审校员")
            ? #"{"exampleUsesTargetSense":true,"translationEquivalent":true,"issues":[]}"#
            : #"{"targetMeaningAccurate":true,"alternativesEquivalent":true,"issues":[]}"#
        return (response(for: request, statusCode: 200), try rawChatResponse(content: review))
    }

    private static let analysisRequest = AIAnalysisRequest(
        english: "What are you up to?",
        chinese: "你最近在忙什么？",
        previousEnglish: "Hey.",
        nextEnglish: "Nothing much."
    )

    private static let analysis = SentenceAnalysis(
        translationZh: "你最近在忙什么？",
        keyExpression: "what are you up to",
        expressionMeaningZh: "询问某人在做什么",
        usageNoteZh: "非正式口语。",
        exampleEnglish: "What are you up to tonight?",
        exampleChinese: "你今晚打算做什么？",
        similarExpressions: [
            SimilarExpression(
                english: "What have you been doing?",
                chinese: "你最近在做什么？"
            ),
            SimilarExpression(
                english: "What are you busy with?",
                chinese: "你在忙些什么？"
            )
        ],
        analyzedEnglish: analysisRequest.contextualEnglish
    )

    private static func response(
        for request: URLRequest,
        statusCode: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func chatResponseData(
        analysis: SentenceAnalysis
    ) throws -> Data {
        let analysisData = try JSONEncoder().encode(analysis)
        let content = String(decoding: analysisData, as: UTF8.self)
        let envelope: [String: Any] = [
            "choices": [
                ["message": ["content": content]]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    private static func rawChatResponse(
        content: String,
        reasoning: String = "",
        finishReason: String = "stop"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": ["content": content, "reasoning_content": reasoning],
                "finish_reason": finishReason
            ]]
        ])
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(bodyData(from: request))) as? [String: Any]
        )
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                return nil
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
