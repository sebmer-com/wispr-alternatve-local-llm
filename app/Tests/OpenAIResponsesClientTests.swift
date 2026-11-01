import Foundation
import XCTest
@testable import FluidPushToTalk

final class OpenAIResponsesClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testCompleteSendsFixedLunaResponsesRequest() async throws {
        let client = makeClient()
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Rewritten"))

        _ = try await client.complete(
            systemPrompt: "Follow the command.",
            userPrompt: "Make this shorter.",
            imageURLs: []
        )

        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try requestJSON(request)
        XCTAssertEqual(json["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((json["text"] as? [String: Any])?["verbosity"] as? String, "low")
        XCTAssertNil(json["max_output_tokens"], "reasoning must not be truncated by an artificial output cap")
        XCTAssertEqual(json["instructions"] as? String, "Follow the command.")

        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.filter { $0["type"] as? String == "input_image" }.count, 0)
    }

    func testCompleteEncodesOnePNGAsLowDetailDataURL() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try imageData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Seen"))
        _ = try await makeClient().complete(
            systemPrompt: "Use the screenshot.",
            userPrompt: "What is visible?",
            imageURLs: [imageURL]
        )

        let request = try XCTUnwrap(URLProtocolStub.requests.first)
        let json = try requestJSON(request)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        let userContent = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(userContent.first { $0["type"] as? String == "input_image" })
        XCTAssertEqual(image["detail"] as? String, "low")
        XCTAssertEqual(
            image["image_url"] as? String,
            "data:image/png;base64,\(imageData.base64EncodedString())"
        )
    }

    func testCompletePreservesOrderOfFiveImages() async throws {
        let imageData = (0..<5).map { Data([0x89, 0x50, 0x4E, UInt8($0)]) }
        let imageURLs = try imageData.enumerated().map { index, data -> URL in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("openai-ordered-\(index)-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try data.write(to: url)
            return url
        }
        defer { imageURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Seen all"))
        _ = try await makeClient().complete(
            systemPrompt: "Use every screenshot.",
            userPrompt: "Compare them in order.",
            imageURLs: imageURLs
        )

        let json = try requestJSON(XCTUnwrap(URLProtocolStub.requests.first))
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        let images = content.filter { $0["type"] as? String == "input_image" }
        XCTAssertEqual(images.count, 5)
        XCTAssertEqual(
            images.compactMap { $0["image_url"] as? String },
            imageData.map { "data:image/png;base64,\($0.base64EncodedString())" }
        )
        XCTAssertTrue(images.allSatisfy { $0["detail"] as? String == "low" })
    }

    func testCompleteReturnsOutputText() async throws {
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("  Final answer  "))

        let result = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: []
        )

        XCTAssertEqual(result, "Final answer")
    }

    func testCompleteThrowsWhenResponseContainsNoOutputText() async {
        URLProtocolStub.enqueue(
            status: 200,
            body: Data(#"{"id":"resp_empty","output":[]}"#.utf8)
        )

        do {
            _ = try await makeClient().complete(
                systemPrompt: "System",
                userPrompt: "User",
                imageURLs: []
            )
            XCTFail("Expected an empty-output error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testCompleteRetriesOnceAfterRateLimit() async throws {
        URLProtocolStub.enqueue(status: 429, body: Data(#"{"error":{"message":"rate limited"}}"#.utf8))
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Recovered"))

        let result = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: []
        )

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
    }

    func testCompleteRetriesOnceAfterServerError() async throws {
        URLProtocolStub.enqueue(status: 503, body: Data(#"{"error":{"message":"unavailable"}}"#.utf8))
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Recovered"))

        let result = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: []
        )

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
    }

    func testCompleteRetriesOnceAfterTimeout() async throws {
        URLProtocolStub.enqueue(error: URLError(.timedOut))
        URLProtocolStub.enqueue(status: 200, body: Self.successBody("Recovered"))

        let result = try await makeClient().complete(
            systemPrompt: "System",
            userPrompt: "User",
            imageURLs: []
        )

        XCTAssertEqual(result, "Recovered")
        XCTAssertEqual(URLProtocolStub.requests.count, 2)
    }

    func testProviderErrorMessageRedactsImageDataAndCredentials() async {
        let hostile = "bad data:image/png;base64,QUJDREVGRw== Bearer secret-token csk-secretvalue123456"
        URLProtocolStub.enqueue(
            status: 400,
            body: try! JSONSerialization.data(withJSONObject: ["error": ["message": hostile]])
        )

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
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-diagnostics-\(UUID().uuidString).png")
        try imageData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        URLProtocolStub.enqueue(
            status: 429,
            body: Data(#"{"error":{"message":"rate limited"}}"#.utf8),
            headers: ["x-request-id": "openai-retry-id"]
        )
        URLProtocolStub.enqueue(
            status: 200,
            body: Self.successBody("Recovered"),
            headers: ["request-id": "openai-success-id"]
        )

        _ = try await makeClient(
            apiKey: "diagnostic-openai-secret",
            logger: capture.logger
        ).complete(systemPrompt: "System", userPrompt: "User", imageURLs: [imageURL])

        let logs = capture.joined
        XCTAssertTrue(logs.contains("request_id="))
        XCTAssertTrue(logs.contains("provider=openai"))
        XCTAssertTrue(logs.contains("model=gpt-6-luna"))
        XCTAssertTrue(logs.contains("prompt_chars=10"))
        XCTAssertTrue(logs.contains("image_count=1"))
        XCTAssertTrue(logs.contains("timeout_seconds=1.000"))
        XCTAssertTrue(logs.contains("payload_bytes="))
        XCTAssertTrue(logs.contains("build_duration_ms="))
        XCTAssertTrue(logs.contains("path=\"\(imageURL.path)\""))
        XCTAssertTrue(logs.contains("bytes=4"))
        XCTAssertTrue(logs.contains("mime=image/png"))
        XCTAssertTrue(logs.contains("base64_chars=8"))
        XCTAssertTrue(logs.contains("sha256="))
        XCTAssertTrue(logs.contains("attempt=1/2"))
        XCTAssertTrue(logs.contains("attempt=2/2"))
        XCTAssertTrue(logs.contains("http_status=429"))
        XCTAssertTrue(logs.contains("response_request_id=\"openai-retry-id\""))
        XCTAssertTrue(logs.contains("response_request_id=\"openai-success-id\""))
        XCTAssertTrue(logs.contains("retry_reason=http_429"))
        XCTAssertTrue(logs.contains("outcome=success"))
        assertDiagnosticsAreSafe(
            logs,
            apiKey: "diagnostic-openai-secret",
            rawBase64: imageData.base64EncodedString()
        )
    }

    func testDiagnosticsLogTerminalTimeoutWithoutSecrets() async {
        let capture = ProviderLogCapture()
        URLProtocolStub.enqueue(error: URLError(.timedOut))

        do {
            _ = try await makeClient(
                maxRetries: 0,
                apiKey: "terminal-openai-secret",
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
            assertDiagnosticsAreSafe(logs, apiKey: "terminal-openai-secret", rawBase64: "")
        }
    }

    private func makeClient(
        maxRetries: Int = 1,
        apiKey: String = "test-api-key",
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) -> OpenAIResponsesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return OpenAIResponsesClient(
            apiKey: apiKey,
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
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

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? requestBodyStreamData(request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func requestBodyStreamData(_ request: URLRequest) -> Data? {
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

    private static func successBody(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": "resp_test",
            "output": [[
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": text]],
            ]],
        ])
    }
}

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private enum Result {
        case response(status: Int, body: Data, headers: [String: String])
        case failure(Error)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuedResults: [Result] = []
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func reset() {
        lock.withLock {
            queuedResults = []
            requests = []
        }
    }

    static func enqueue(status: Int, body: Data, headers: [String: String] = [:]) {
        lock.withLock { queuedResults.append(.response(status: status, body: body, headers: headers)) }
    }

    static func enqueue(error: Error) {
        lock.withLock { queuedResults.append(.failure(error)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result = Self.lock.withLock { () -> Result? in
            Self.requests.append(request)
            return Self.queuedResults.isEmpty ? nil : Self.queuedResults.removeFirst()
        }
        guard let result else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if case let .failure(error) = result {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard case let .response(status, body, headers) = result,
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new }
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ProviderLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    var logger: @Sendable (String) -> Void {
        { [weak self] message in
            self?.lock.withLock {
                self?.messages.append(message)
            }
        }
    }

    var joined: String {
        lock.withLock { messages.joined(separator: "\n") }
    }
}
