import Foundation
import XCTest
@testable import FluidPushToTalk

final class GeminiClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testCompleteSendsFixedGeminiRequestWithoutImages() async throws {
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Done"))

        _ = try await makeClient().complete(
            systemPrompt: "System rules",
            userPrompt: "User command",
            imageURLs: []
        )

        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent"
        )
        XCTAssertTrue(request.url?.absoluteString.contains("gemini-3.5-flash") ?? false)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-gemini-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "fluid-push-to-talk/0.2.3")

        let json = try requestJSON(request)
        let generationConfig = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["temperature"] as? Double, 0.2)
        XCTAssertEqual(generationConfig["maxOutputTokens"] as? Int, 256)

        let systemInstruction = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
        let systemParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
        XCTAssertEqual(systemParts.first?["text"] as? String, "System rules")

        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["text"] as? String, "User command")
    }

    func testCompleteEncodesOneImageUsingGeminiInlineDataSchema() async throws {
        let fixture = try makeImages(count: 1)
        defer { fixture.urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Seen"))

        _ = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: fixture.urls
        )

        let inlineParts = try inlineDataParts(from: XCTUnwrap(URLProtocolStub.requests.first))
        XCTAssertEqual(inlineParts.count, 1)
        let inlineData = try XCTUnwrap(inlineParts[0]["inlineData"] as? [String: Any])
        XCTAssertEqual(inlineData["mimeType"] as? String, "image/png")
        let base64 = try XCTUnwrap(inlineData["data"] as? String)
        XCTAssertFalse(base64.hasPrefix("data:"))
        XCTAssertEqual(base64, fixture.rawBase64[0])
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

        let inlineParts = try inlineDataParts(from: XCTUnwrap(URLProtocolStub.requests.first))
        XCTAssertEqual(inlineParts.count, 5)
        XCTAssertEqual(
            inlineParts.compactMap { ($0["inlineData"] as? [String: Any])?["data"] as? String },
            fixture.rawBase64
        )
    }

    func testCompleteReturnsTrimmedCandidateText() async throws {
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("  Gemini answer  "))

        let result = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: []
        )

        XCTAssertEqual(result, "Gemini answer")
    }

    func testCompleteJoinsMultiplePartsOfText() async throws {
        URLProtocolStub.enqueue(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: [
                "candidates": [
                    [
                        "content": ["parts": [["text": "  Multi-part "], ["text": "response.  "]]],
                        "finishReason": "STOP",
                    ],
                ],
            ])
        )

        let result = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: []
        )

        XCTAssertEqual(result, "Multi-part response.")
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

    func testCompletePropagatesBadRequestWithoutRetry() async {
        URLProtocolStub.enqueue(status: 400, body: Self.errorBody("invalid argument"))

        await assertFailureContains("invalid argument")
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompletePropagatesForbiddenWithoutRetry() async {
        URLProtocolStub.enqueue(status: 403, body: Self.errorBody("forbidden"))

        await assertFailureContains("forbidden")
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompleteThrowsBlockedWhenPromptFeedbackBlocksWithNoCandidates() async {
        URLProtocolStub.enqueue(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: [
                "promptFeedback": ["blockReason": "SAFETY"],
            ])
        )

        do {
            _ = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])
            XCTFail("Expected a blocked error")
        } catch let error as GeminiError {
            XCTAssertEqual(error, .blocked(reason: "SAFETY"))
        } catch {
            XCTFail("Expected GeminiError.blocked, got \(error)")
        }
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompleteThrowsBlockedWhenCandidateHasEmptyTextAndNonStopFinishReason() async {
        URLProtocolStub.enqueue(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: [
                "candidates": [
                    ["content": ["parts": []], "finishReason": "SAFETY"],
                ],
            ])
        )

        do {
            _ = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])
            XCTFail("Expected a blocked error")
        } catch let error as GeminiError {
            XCTAssertEqual(error, .blocked(reason: "SAFETY"))
        } catch {
            XCTFail("Expected GeminiError.blocked, got \(error)")
        }
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func testCompleteReturnsTextWhenFinishReasonIsMaxTokensWithNonEmptyText() async throws {
        URLProtocolStub.enqueue(
            status: 200,
            body: try! JSONSerialization.data(withJSONObject: [
                "candidates": [
                    ["content": ["parts": [["text": "Truncated but present"]]], "finishReason": "MAX_TOKENS"],
                ],
            ])
        )

        let result = try await makeClient().complete(systemPrompt: "S", userPrompt: "U", imageURLs: [])

        XCTAssertEqual(result, "Truncated but present")
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
            headers: ["x-request-id": "gemini-retry-id"]
        )
        URLProtocolStub.enqueue(
            status: 200,
            body: Self.successBody("Recovered"),
            headers: ["request-id": "gemini-success-id"]
        )

        _ = try await makeClient(
            apiKey: "diagnostic-gemini-secret",
            logger: capture.logger
        ).complete(systemPrompt: "System", userPrompt: "User", imageURLs: fixture.urls)

        let logs = capture.joined
        XCTAssertTrue(logs.contains("request_id="))
        XCTAssertTrue(logs.contains("provider=gemini"))
        XCTAssertTrue(logs.contains("model=gemini-3.5-flash"))
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
        XCTAssertTrue(logs.contains("response_request_id=\"gemini-retry-id\""))
        XCTAssertTrue(logs.contains("response_request_id=\"gemini-success-id\""))
        XCTAssertTrue(logs.contains("retry_reason=http_5xx"))
        XCTAssertTrue(logs.contains("outcome=success"))
        assertDiagnosticsAreSafe(
            logs,
            apiKey: "diagnostic-gemini-secret",
            rawBase64: fixture.rawBase64[0]
        )
    }

    func testDiagnosticsLogTerminalTimeoutWithoutSecrets() async {
        let capture = ProviderLogCapture()
        URLProtocolStub.enqueue(error: URLError(.timedOut))

        do {
            _ = try await makeClient(
                maxRetries: 0,
                apiKey: "terminal-gemini-secret",
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
            assertDiagnosticsAreSafe(logs, apiKey: "terminal-gemini-secret", rawBase64: "")
        }
    }

    private func makeClient(
        maxRetries: Int = 1,
        apiKey: String = "test-gemini-key",
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) -> GeminiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return GeminiClient(
            apiKey: apiKey,
            endpoint: URL(
                string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent"
            )!,
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

    private func contentParts(from request: URLRequest) throws -> [[String: Any]] {
        let json = try requestJSON(request)
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        return try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
    }

    private func inlineDataParts(from request: URLRequest) throws -> [[String: Any]] {
        let parts = try contentParts(from: request)
        return parts.filter { $0["inlineData"] != nil }
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

    private func makeImages(count: Int) throws -> (urls: [URL], rawBase64: [String]) {
        var urls: [URL] = []
        var rawBase64: [String] = []
        for index in 0..<count {
            let data = Data([0x89, 0x50, 0x4E, UInt8(index)])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gemini-ordered-\(index)-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try data.write(to: url)
            urls.append(url)
            rawBase64.append(data.base64EncodedString())
        }
        return (urls, rawBase64)
    }

    private static func successBody(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "candidates": [
                ["content": ["parts": [["text": text]]], "finishReason": "STOP"],
            ],
        ])
    }

    private static func errorBody(_ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
    }
}
