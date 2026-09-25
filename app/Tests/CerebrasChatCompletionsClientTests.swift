import Foundation
import XCTest
@testable import FluidPushToTalk

final class CerebrasChatCompletionsClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testCompleteSendsFixedCerebrasRequestWithoutImages() async throws {
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Done"))

        _ = try await makeClient().complete(
            systemPrompt: "System rules",
            userPrompt: "User command",
            imageURLs: []
        )

        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.cerebras.ai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-cerebras-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "fluid-push-to-talk/0.2.3")
        let json = try requestJSON(request)
        XCTAssertEqual(json["model"] as? String, "qwen-3.8-27b")
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 4_096)
        XCTAssertNil(json["max_tokens"])
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "System rules")
        let userContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.filter { $0["type"] as? String == "image_url" }.count, 0)
    }

    func testCompleteEncodesOneImageUsingChatCompletionsSchema() async throws {
        let fixture = try makeImages(count: 1)
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Seen"))

        _ = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: fixture.urls
        )

        let images = try imageParts(from: XCTUnwrap(URLProtocolStub.requests.first))
        XCTAssertEqual(images.count, 1)
        let imageURL = try XCTUnwrap(images[0]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, fixture.dataURLs[0])
    }

    func testCompletePreservesOrderOfFiveImages() async throws {
        let fixture = try makeImages(count: 5)
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Seen all"))

        _ = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: fixture.urls
        )

        let images = try imageParts(from: XCTUnwrap(URLProtocolStub.requests.first))
        XCTAssertEqual(images.count, 5)
        XCTAssertEqual(
            images.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String },
            fixture.dataURLs
        )
    }

    func testCompleteReturnsAssistantContent() async throws {
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("  Cerebras answer  "))

        let result = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: []
        )

        XCTAssertEqual(result, "Cerebras answer")
    }

    func testReasoningOnlyAtTokenLimitReportsCompletionLimit() async {
        await assertResponseFailure(
            #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","reasoning":"private reasoning"}}]}"#,
            expected: .completionLimitExceeded
        )
    }

    func testPartialAnswerAtTokenLimitIsNotDelivered() async {
        await assertResponseFailure(
            #"{"choices":[{"finish_reason":"length","message":{"content":"unfinished answer"}}]}"#,
            expected: .completionLimitExceeded
        )
    }

    func testMissingOrNullContentWithoutTokenLimitIsEmptyResponse() async {
        for message in [#"{"reasoning":"private reasoning"}"#, #"{"content":null}"#] {
            URLProtocolStub.reset()
            await assertResponseFailure(
                "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":\(message)}]}",
                expected: .emptyResponse
            )
        }
    }

    func testMalformedContentRemainsInvalidResponse() async {
        await assertResponseFailure(
            #"{"choices":[{"message":{"content":42}}]}"#,
            expected: .invalidResponse
        )
    }

    func testCompleteReturnsOnlyAnswerWhenReasoningIsPresent() async throws {
        URLProtocolStub.enqueue(status: 200, body: Data(
            #"{"choices":[{"finish_reason":"stop","message":{"content":" Done ","reasoning":"private reasoning"}}]}"#.utf8
        ))
        let result = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])
        XCTAssertEqual(result, "Done")
    }

    private func assertResponseFailure(
        _ body: String,
        expected: CerebrasChatCompletionsError
    ) async {
        URLProtocolStub.enqueue(status: 200, body: Data(body.utf8))
        do {
            _ = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])
            XCTFail("Expected response failure")
        } catch {
            XCTAssertEqual(error as? CerebrasChatCompletionsError, expected)
        }
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompletePropagatesPaymentRequiredWithoutRetry() async {
        URLProtocolStub.enqueue(status: 402, body: Self.errorBody("payment required"))

        await assertFailureContains("payment required")
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompleteDecodesTopLevelCerebrasErrorMessage() async {
        URLProtocolStub.enqueue(
            status: 402,
            body: Data(#"{"message":"billing quota exhausted"}"#.utf8)
        )

        await assertFailureContains("billing quota exhausted")
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompletePropagatesForbiddenWithoutRetry() async {
        URLProtocolStub.enqueue(status: 403, body: Self.errorBody("forbidden"))

        await assertFailureContains("forbidden")
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompleteRetriesRateLimitOnce() async throws {
        URLProtocolStub.enqueue(status: 429, body: Self.errorBody("rate limited"))
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Recovered"))

        let result = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
    }

    func testCompleteRetriesServerErrorOnce() async throws {
        URLProtocolStub.enqueue(status: 503, body: Self.errorBody("unavailable"))
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Recovered"))

        let result = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
    }

    func testCompleteRetriesTimeoutOnce() async throws {
        URLProtocolStub.enqueue(error: URLError(.timedOut))
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Recovered"))

        let result = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
    }

    func testProviderErrorMessageRedactsImageDataAndCredentials() async {
        let hostile = "bad data:image/png;base64,QUJDREVGRw== Bearer secret-token csk-secretvalue123456"
        URLProtocolStub.enqueue(status: 400, body: Self.errorBody(hostile))

        do {
            _ = try await makeClient(maxRetries: 0).complete(
                systemPrompt: "System",
                userPrompt: "User",
                imageURLs: []
            )
            XCTFail("Expected provider error")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("<redacted-data-url>"))
            XCTAssertFalse(description.contains("QUJDREVGRw"))
            XCTAssertFalse(description.contains("secret-token"))
            XCTAssertFalse(description.contains("csk-secret"))
        }
    }

    func testDiagnosticsLogRetryThenSuccessWithoutSecretsOrBase64() async throws {
        let capture = ProviderLogCapture()
        let fixture = try makeImages(count: 1)
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        URLProtocolStub.enqueue(
            status: 503,
            body: Self.errorBody("unavailable"),
            headers: ["x-request-id": "cerebras-retry-id"]
        )
        URLProtocolStub.enqueue(
            status: 200,
            body: Self.successBody("Recovered"),
            headers: ["request-id": "cerebras-success-id"]
        )

        _ = try await makeClient(
            apiKey: "diagnostic-cerebras-secret",
            logger: capture.logger
        ).complete(systemPrompt: "System", userPrompt: "User", imageURLs: fixture.urls)

        let logs = capture.joined
        XCTAssertTrue(logs.contains("request_id="))
        XCTAssertTrue(logs.contains("provider=cerebras"))
        XCTAssertTrue(logs.contains("model=qwen-3.8-27b"))
        XCTAssertTrue(logs.contains("prompt_chars=10"))
        XCTAssertTrue(logs.contains("image_count=1"))
        XCTAssertTrue(logs.contains("timeout_seconds=1.000"))
        XCTAssertTrue(logs.contains("payload_bytes="))
        XCTAssertTrue(logs.contains("build_duration_ms="))
        XCTAssertTrue(logs.contains("path=\"\(fixture.urls[0].path)\""))
        XCTAssertTrue(logs.contains("bytes=4"))
        XCTAssertTrue(logs.contains("mime=image/png"))
        XCTAssertTrue(logs.contains("base64_chars=8"))
        XCTAssertTrue(logs.contains("sha256="))
        XCTAssertTrue(logs.contains("attempt=1/2"))
        XCTAssertTrue(logs.contains("attempt=2/2"))
        XCTAssertTrue(logs.contains("http_status=503"))
        XCTAssertTrue(logs.contains("response_request_id=\"cerebras-retry-id\""))
        XCTAssertTrue(logs.contains("response_request_id=\"cerebras-success-id\""))
        XCTAssertTrue(logs.contains("retry_reason=http_5xx"))
        XCTAssertTrue(logs.contains("outcome=success"))
        assertDiagnosticsAreSafe(
            logs,
            apiKey: "diagnostic-cerebras-secret",
            rawBase64: fixture.dataURLs[0].components(separatedBy: ",").last ?? ""
        )
    }

    func testDiagnosticsLogTerminalTimeoutWithoutSecrets() async {
        let capture = ProviderLogCapture()
        URLProtocolStub.enqueue(error: URLError(.timedOut))

        do {
            _ = try await makeClient(
                maxRetries: 0,
                apiKey: "terminal-cerebras-secret",
                logger: capture.logger
            ).complete(systemPrompt: "System", userPrompt: "User", imageURLs: [])
            XCTFail("Expected timeout")
        } catch {
            let logs = capture.joined
            XCTAssertTrue(logs.contains("attempt=1/1"))
            XCTAssertTrue(logs.contains("outcome=failure"))
            XCTAssertTrue(logs.contains("http_status=none"))
            XCTAssertTrue(logs.contains("error_domain=\"NSURLErrorDomain\""))
            XCTAssertTrue(logs.contains("error_code=-1001"))
            XCTAssertFalse(logs.contains("retry_reason="))
            assertDiagnosticsAreSafe(logs, apiKey: "terminal-cerebras-secret", rawBase64: "")
        }
    }

    private func makeClient(
        maxRetries: Int = 1,
        apiKey: String = "test-cerebras-key",
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CerebrasChatCompletionsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return CerebrasChatCompletionsClient(
            apiKey: apiKey,
            endpoint: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
            session: URLSession(configuration: configuration),
            requestTimeout: 1,
            maxRetries: maxRetries,
            logger: logger
        )
    }

    private func assertDiagnosticsAreSafe(_ logs: String, apiKey: String, rawBase64: String) {
        XCTAssertFalse(logs.contains(apiKey))
        XCTAssertFalse(logs.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(logs.contains("data:image"))
        if !rawBase64.isEmpty {
            XCTAssertFalse(logs.contains(rawBase64))
        }
    }

    private func assertFailureContains(_ expected: String) async {
        do {
            _ = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])
            XCTFail("Expected request to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(expected))
        }
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? bodyStreamData(request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func imageParts(from request: URLRequest) throws -> [[String: Any]] {
        let json = try requestJSON(request)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        return content.filter { $0["type"] as? String == "image_url" }
    }

    private func bodyStreamData(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func makeImages(count: Int) throws -> (urls: [URL], dataURLs: [String]) {
        var urls: [URL] = []
        var dataURLs: [String] = []
        for index in 0..<count {
            let data = Data([0x89, 0x50, 0x4E, UInt8(index)])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cerebras-ordered-\(index)-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try data.write(to: url)
            urls.append(url)
            dataURLs.append("data:image/png;base64,\(data.base64EncodedString())")
        }
        return (urls, dataURLs)
    }

    private static func successBody(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": text]]],
        ])
    }

    private static func errorBody(_ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
    }
}
