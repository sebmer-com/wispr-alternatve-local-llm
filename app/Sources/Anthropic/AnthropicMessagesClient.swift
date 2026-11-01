import Foundation

/// Native API-key Messages transport. Subscription OAuth is intentionally not used here.
final class AnthropicMessagesClient: CommandLLMClient, Sendable {
    static let model = "claude-haiku-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiKeyEnvironmentName = "ANTHROPIC_API_KEY"
    private let apiKey: String
    private let configuredModel: String
    private let endpoint: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let logger: @Sendable (String) -> Void

    var displayName: String { "Anthropic \(configuredModel)" }

    init(
        apiKey: String,
        model: String = AnthropicMessagesClient.model,
        endpoint: URL = AnthropicMessagesClient.endpoint,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 60,
        logger: @escaping @Sendable (String) -> Void = log
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuredModel = model
        self.endpoint = endpoint
        self.session = session
        self.requestTimeout = requestTimeout
        self.logger = logger
    }

    func complete(systemPrompt: String, userPrompt: String, imageURLs: [URL] = []) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicMessagesError.missingAPIKey }
        guard imageURLs.count <= 5 else { throw AnthropicMessagesError.tooManyImages }
        guard !configuredModel.isEmpty, requestTimeout.isFinite, requestTimeout > 0 else {
            throw AnthropicMessagesError.invalidConfiguration
        }
        let requestID = UUID().uuidString
        let started = Date()
        // Reading screenshots and Base64/payload encoding are blocking; never do them on UI queues.
        let (request, attachments) = try await Task.detached(priority: .userInitiated) { [self] in
            try makeRequest(systemPrompt: systemPrompt, userPrompt: userPrompt, imageURLs: imageURLs)
        }.value
        CommandRequestDiagnostics.logRequest(logger: logger, requestID: requestID, provider: "anthropic",
            model: configuredModel, systemPrompt: systemPrompt, userPrompt: userPrompt,
            attachments: attachments, timeout: requestTimeout, payloadBytes: request.httpBody?.count ?? 0,
            buildDuration: Date().timeIntervalSince(started))
        CommandRequestDiagnostics.logAttemptStart(logger: logger, requestID: requestID, provider: "anthropic", attempt: 1, maximumAttempts: 1)
        let attemptStarted = Date()
        var metadata: CommandHTTPResponseMetadata?
        do {
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    throw AnthropicMessagesError.timeout
                }
                throw AnthropicMessagesError.transport
            }
            guard let http = response as? HTTPURLResponse else { throw AnthropicMessagesError.nonHTTPResponse }
            metadata = CommandRequestDiagnostics.responseMetadata(data: data, response: http)
            guard (200..<300).contains(http.statusCode) else { throw AnthropicMessagesError.http(statusCode: http.statusCode) }
            let text = try decode(data)
            CommandRequestDiagnostics.logAttemptResult(logger: logger, requestID: requestID, provider: "anthropic",
                attempt: 1, maximumAttempts: 1, outcome: "success", duration: Date().timeIntervalSince(attemptStarted), response: metadata)
            return text
        } catch {
            CommandRequestDiagnostics.logAttemptResult(logger: logger, requestID: requestID, provider: "anthropic",
                attempt: 1, maximumAttempts: 1, outcome: "failure", duration: Date().timeIntervalSince(attemptStarted), response: metadata, error: error)
            CommandRequestDiagnostics.logTerminalFailure(logger: logger, requestID: requestID, provider: "anthropic", error: error)
            throw error
        }
    }

    private func makeRequest(systemPrompt: String, userPrompt: String, imageURLs: [URL]) throws -> (URLRequest, [CommandImageAttachment]) {
        for url in imageURLs {
            do {
                guard url.isFileURL, url.pathExtension.lowercased() == "png" else { throw AnthropicMessagesError.invalidImage }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AnthropicMessagesError.invalidImage }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard try handle.read(upToCount: 8) == Data([137,80,78,71,13,10,26,10]) else { throw AnthropicMessagesError.invalidImage }
            } catch { throw AnthropicMessagesError.invalidImage }
        }
        let attachments: [CommandImageAttachment]
        do { attachments = try CommandRequestDiagnostics.loadAttachments(from: imageURLs) }
        catch { throw AnthropicMessagesError.invalidImage }
        var content: [[String: Any]] = [["type": "text", "text": userPrompt]]
        for attachment in attachments {
            // The shared diagnostics attachment already contains exactly one Base64 encoding.
            let base64 = String(attachment.dataURL.dropFirst("data:image/png;base64,".count))
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]])
        }
        var payload: [String: Any] = [
            "model": configuredModel, "system": systemPrompt, "max_tokens": 8192,
            "messages": [["role": "user", "content": content]],
        ]
        // Haiku 5.5 enables adaptive thinking by default; use effort, not a legacy token budget.
        if configuredModel.hasPrefix(Self.model) {
            payload["thinking"] = ["type": "adaptive"]
            payload["output_config"] = ["effort": "low"]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return (request, attachments)
    }

    private func decode(_ data: Data) throws -> String {
        guard let payload = try? JSONDecoder().decode(MessagesResponse.self, from: data),
              payload.type == "message", payload.role == "assistant" else { throw AnthropicMessagesError.invalidResponse }
        if payload.stop_reason == "max_tokens" { throw AnthropicMessagesError.truncated }
        if payload.stop_reason == "refusal" || payload.content.contains(where: { $0.type == "refusal" }) {
            throw AnthropicMessagesError.refusal
        }
        guard ["end_turn", "stop_sequence"].contains(payload.stop_reason),
              payload.content.allSatisfy({ ($0.type == "text" && $0.text != nil) || ["thinking", "redacted_thinking"].contains($0.type) }) else { throw AnthropicMessagesError.invalidResponse }
        let answer = payload.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AnthropicMessagesError.emptyResponse }
        return answer
    }
}

private struct MessagesResponse: Decodable {
    let type: String
    let role: String
    let stop_reason: String
    let content: [Block]
    struct Block: Decodable { let type: String; let text: String? }
}

enum AnthropicMessagesError: Error, LocalizedError, Equatable {
    case missingAPIKey, invalidConfiguration, tooManyImages, invalidImage, nonHTTPResponse
    case http(statusCode: Int)
    case invalidResponse, emptyResponse, truncated, refusal, timeout, transport
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "ANTHROPIC_API_KEY is not configured"
        case .invalidConfiguration: return "Anthropic command configuration is invalid"
        case .tooManyImages: return "Anthropic accepts at most five screenshots per command"
        case .invalidImage: return "Anthropic requires existing regular PNG screenshot files"
        case .nonHTTPResponse: return "Anthropic returned a non-HTTP response"
        case let .http(statusCode): return "Anthropic Messages request failed with HTTP \(statusCode)"
        case .invalidResponse: return "Anthropic returned an invalid Messages payload"
        case .emptyResponse: return "Anthropic returned no answer text"
        case .truncated: return "Anthropic exhausted the token budget before finishing the answer"
        case .refusal: return "Anthropic declined the command"
        case .timeout: return "Anthropic Messages request timed out"
        case .transport: return "Anthropic Messages transport failed"
        }
    }
}
