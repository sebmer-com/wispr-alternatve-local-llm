import Foundation

final class CerebrasChatCompletionsClient: CommandLLMClient, @unchecked Sendable {
    static let endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions")!
    static let model = "qwen-3.8-27b"
    static let temperature = 0.2
    // Qwen counts reasoning and visible output against the same completion budget.
    static let maxCompletionTokens = 4_096
    static let reasoningEffort = "low"
    static let maximumImages = 5
    static let userAgent = "fluid-push-to-talk/0.2.3"

    private let apiKey: String
    private let requestURL: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let maxRetries: Int
    private let logger: @Sendable (String) -> Void

    var displayName: String {
        "Cerebras \(Self.model)"
    }

    init(
        apiKey: String,
        endpoint: URL = CerebrasChatCompletionsClient.endpoint,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 30,
        maxRetries: Int = 1,
        logger: @escaping @Sendable (String) -> Void = log
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        requestURL = endpoint
        self.session = session
        self.requestTimeout = requestTimeout
        self.maxRetries = max(0, maxRetries)
        self.logger = logger
    }

    func complete(systemPrompt: String, userPrompt: String, imageURLs: [URL] = []) async throws -> String {
        guard imageURLs.count <= Self.maximumImages else {
            throw CerebrasChatCompletionsError.tooManyImages(maximum: Self.maximumImages)
        }
        guard !apiKey.isEmpty else {
            throw CerebrasChatCompletionsError.missingAPIKey
        }

        let requestID = UUID().uuidString
        let buildStartedAt = Date()
        let attachments = try CommandRequestDiagnostics.loadAttachments(from: imageURLs)
        let request = try makeRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            attachments: attachments
        )
        CommandRequestDiagnostics.logRequest(
            logger: logger,
            requestID: requestID,
            provider: "cerebras",
            model: Self.model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            attachments: attachments,
            timeout: requestTimeout,
            payloadBytes: request.httpBody?.count ?? 0,
            buildDuration: Date().timeIntervalSince(buildStartedAt)
        )

        let maximumAttempts = maxRetries + 1
        for attempt in 1...maximumAttempts {
            CommandRequestDiagnostics.logAttemptStart(
                logger: logger,
                requestID: requestID,
                provider: "cerebras",
                attempt: attempt,
                maximumAttempts: maximumAttempts
            )
            let attemptStartedAt = Date()
            var responseMetadata: CommandHTTPResponseMetadata?
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CerebrasChatCompletionsError.nonHTTPResponse
                }
                responseMetadata = CommandRequestDiagnostics.responseMetadata(data: data, response: httpResponse)
                let content = try decodeResponse(data: data, response: httpResponse)
                CommandRequestDiagnostics.logAttemptResult(
                    logger: logger,
                    requestID: requestID,
                    provider: "cerebras",
                    attempt: attempt,
                    maximumAttempts: maximumAttempts,
                    outcome: "success",
                    duration: Date().timeIntervalSince(attemptStartedAt),
                    response: responseMetadata
                )
                return content
            } catch {
                CommandRequestDiagnostics.logAttemptResult(
                    logger: logger,
                    requestID: requestID,
                    provider: "cerebras",
                    attempt: attempt,
                    maximumAttempts: maximumAttempts,
                    outcome: "failure",
                    duration: Date().timeIntervalSince(attemptStartedAt),
                    response: responseMetadata,
                    error: error
                )
                guard attempt < maximumAttempts, let retryReason = retryReason(for: error) else {
                    CommandRequestDiagnostics.logTerminalFailure(
                        logger: logger,
                        requestID: requestID,
                        provider: "cerebras",
                        error: error
                    )
                    throw error
                }
                CommandRequestDiagnostics.logRetry(
                    logger: logger,
                    requestID: requestID,
                    provider: "cerebras",
                    reason: retryReason
                )
            }
        }
        preconditionFailure("Cerebras request attempt loop exhausted unexpectedly")
    }

    private func makeRequest(
        systemPrompt: String,
        userPrompt: String,
        attachments: [CommandImageAttachment]
    ) throws -> URLRequest {
        var userContent: [ChatCompletionsRequest.Content] = [.text(userPrompt)]
        userContent.append(contentsOf: attachments.map { attachment in
            .imageURL(attachment.dataURL)
        })
        let payload = ChatCompletionsRequest(
            model: Self.model,
            messages: [
                .init(role: "system", content: .plainText(systemPrompt)),
                .init(role: "user", content: .parts(userContent)),
            ],
            temperature: Self.temperature,
            maxCompletionTokens: Self.maxCompletionTokens,
            reasoningEffort: Self.reasoningEffort
        )

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func decodeResponse(data: Data, response httpResponse: HTTPURLResponse) throws -> String {
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CerebrasChatCompletionsError.http(
                statusCode: httpResponse.statusCode,
                message: errorSummary(from: data)
            )
        }

        let payload: ChatCompletionsResponse
        do {
            payload = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        } catch {
            throw CerebrasChatCompletionsError.invalidResponse
        }
        guard let choice = payload.choices.first else {
            throw CerebrasChatCompletionsError.emptyResponse
        }
        // Never deliver a partial answer or substitute the model's private reasoning.
        guard choice.finishReason != "length" else {
            throw CerebrasChatCompletionsError.completionLimitExceeded
        }
        let content = choice.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw CerebrasChatCompletionsError.emptyResponse
        }
        return content
    }

    private func retryReason(for error: Error) -> String? {
        if case let CerebrasChatCompletionsError.http(statusCode, _) = error {
            if statusCode == 429 { return "http_429" }
            if (500..<600).contains(statusCode) { return "http_5xx" }
            return nil
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
            ? "timeout"
            : nil
    }

    private func errorSummary(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(CerebrasErrorResponse.self, from: data),
           !payload.error.message.isEmpty {
            return CommandRequestDiagnostics.sanitizedProviderMessage(payload.error.message)
        }
        if let payload = try? JSONDecoder().decode(CerebrasDirectErrorResponse.self, from: data),
           !payload.message.isEmpty {
            return CommandRequestDiagnostics.sanitizedProviderMessage(payload.message)
        }
        return "request failed"
    }

}

enum CerebrasChatCompletionsError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case tooManyImages(maximum: Int)
    case nonHTTPResponse
    case http(statusCode: Int, message: String)
    case invalidResponse
    case emptyResponse
    case completionLimitExceeded

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "CEREBRAS_API_KEY is not configured"
        case let .tooManyImages(maximum): return "Cerebras accepts at most \(maximum) screenshots per command"
        case .nonHTTPResponse: return "Cerebras returned a non-HTTP response"
        case let .http(statusCode, message):
            return "Cerebras Chat Completions request failed with HTTP \(statusCode): \(message)"
        case .invalidResponse: return "Cerebras returned an invalid Chat Completions payload"
        case .emptyResponse: return "Cerebras returned no answer text"
        case .completionLimitExceeded:
            return "Cerebras exhausted the completion token budget before finishing the answer"
        }
    }
}

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxCompletionTokens: Int
    let reasoningEffort: String

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxCompletionTokens = "max_completion_tokens"
        case reasoningEffort = "reasoning_effort"
    }

    struct Message: Encodable {
        let role: String
        let content: MessageContent
    }

    enum MessageContent: Encodable {
        case plainText(String)
        case parts([Content])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .plainText(text): try container.encode(text)
            case let .parts(parts): try container.encode(parts)
            }
        }
    }

    enum Content: Encodable {
        case text(String)
        case imageURL(String)

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        enum ImageURLCodingKeys: String, CodingKey {
            case url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .imageURL(url):
                try container.encode("image_url", forKey: .type)
                var imageContainer = container.nestedContainer(
                    keyedBy: ImageURLCodingKeys.self,
                    forKey: .imageURL
                )
                try imageContainer.encode(url, forKey: .url)
            }
        }
    }
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    struct Message: Decodable { let content: String? }
}

private struct CerebrasErrorResponse: Decodable {
    let error: APIError
    struct APIError: Decodable { let message: String }
}

private struct CerebrasDirectErrorResponse: Decodable {
    let message: String
}
