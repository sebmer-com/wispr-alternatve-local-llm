import Foundation

final class OpenAIResponsesClient: CommandLLMClient, @unchecked Sendable {
    static let model = "gpt-6-luna"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let reasoningEffort = "low"
    static let imageDetail = "low"
    static let apiKeyEnvironmentName = "OPENAI_API_KEY"

    private let apiKey: String
    private let requestURL: URL
    private let configuredModel: String
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let maxRetries: Int
    private let logger: @Sendable (String) -> Void

    var displayName: String {
        "OpenAI \(configuredModel)"
    }

    init(
        apiKey: String,
        model: String = OpenAIResponsesClient.model,
        endpoint: URL = OpenAIResponsesClient.endpoint,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 30,
        maxRetries: Int = 1,
        logger: @escaping @Sendable (String) -> Void = log
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        requestURL = endpoint
        configuredModel = model
        self.session = session
        self.requestTimeout = requestTimeout
        self.maxRetries = max(0, maxRetries)
        self.logger = logger
    }

    func complete(systemPrompt: String, userPrompt: String, imageURLs: [URL] = []) async throws -> String {
        guard imageURLs.count <= 5 else {
            throw OpenAIResponsesError.tooManyImages(maximum: 5)
        }
        guard !apiKey.isEmpty else {
            throw OpenAIResponsesError.missingAPIKey
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
            provider: "openai",
            model: configuredModel,
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
                provider: "openai",
                attempt: attempt,
                maximumAttempts: maximumAttempts
            )
            let attemptStartedAt = Date()
            var responseMetadata: CommandHTTPResponseMetadata?
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIResponsesError.nonHTTPResponse
                }
                responseMetadata = CommandRequestDiagnostics.responseMetadata(data: data, response: httpResponse)
                let content = try decodeResponse(data: data, response: httpResponse)
                CommandRequestDiagnostics.logAttemptResult(
                    logger: logger,
                    requestID: requestID,
                    provider: "openai",
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
                    provider: "openai",
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
                        provider: "openai",
                        error: error
                    )
                    throw error
                }
                CommandRequestDiagnostics.logRetry(
                    logger: logger,
                    requestID: requestID,
                    provider: "openai",
                    reason: retryReason
                )
            }
        }
        preconditionFailure("OpenAI request attempt loop exhausted unexpectedly")
    }

    private func makeRequest(
        systemPrompt: String,
        userPrompt: String,
        attachments: [CommandImageAttachment]
    ) throws -> URLRequest {
        var content: [ResponsesRequest.Content] = [.inputText(userPrompt)]
        content.append(contentsOf: attachments.map { attachment in
            .inputImage(
                imageURL: attachment.dataURL,
                detail: Self.imageDetail
            )
        })

        let payload = ResponsesRequest(
            model: configuredModel,
            instructions: systemPrompt,
            input: [.init(role: "user", content: content)],
            reasoning: .init(effort: Self.reasoningEffort),
            text: .init(verbosity: "low"),
            store: false
        )

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func decodeResponse(data: Data, response httpResponse: HTTPURLResponse) throws -> String {
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIResponsesError.http(
                statusCode: httpResponse.statusCode,
                message: errorSummary(from: data)
            )
        }

        let responsePayload: ResponsesResponse
        do {
            responsePayload = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        } catch {
            throw OpenAIResponsesError.invalidResponse
        }
        guard responsePayload.status != "incomplete" else {
            throw OpenAIResponsesError.incompleteResponse(
                reason: responsePayload.incompleteDetails?.reason
            )
        }

        let outputText = responsePayload.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outputText.isEmpty else {
            throw OpenAIResponsesError.emptyResponse
        }
        return outputText
    }

    private func retryReason(for error: Error) -> String? {
        if case let OpenAIResponsesError.http(statusCode, _) = error {
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
        if let payload = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data),
           !payload.error.message.isEmpty {
            return CommandRequestDiagnostics.sanitizedProviderMessage(payload.error.message)
        }
        return "request failed"
    }

}

enum OpenAIResponsesError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case nonHTTPResponse
    case http(statusCode: Int, message: String)
    case invalidResponse
    case incompleteResponse(reason: String?)
    case emptyResponse
    case tooManyImages(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OPENAI_API_KEY is not configured"
        case .nonHTTPResponse: return "OpenAI returned a non-HTTP response"
        case let .http(statusCode, message):
            return "OpenAI Responses request failed with HTTP \(statusCode): \(message)"
        case .invalidResponse: return "OpenAI returned an invalid Responses payload"
        case let .incompleteResponse(reason):
            return "OpenAI returned an incomplete response\(reason.map { ": \($0)" } ?? "")"
        case .emptyResponse: return "OpenAI returned an empty response"
        case let .tooManyImages(maximum): return "OpenAI accepts at most \(maximum) screenshots per command"
        }
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [Input]
    let reasoning: Reasoning
    let text: Text
    let store: Bool

    struct Input: Encodable {
        let role: String
        let content: [Content]
    }

    enum Content: Encodable {
        case inputText(String)
        case inputImage(imageURL: String, detail: String)

        enum CodingKeys: String, CodingKey {
            case type, text, detail
            case imageURL = "image_url"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .inputText(text):
                try container.encode("input_text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .inputImage(imageURL, detail):
                try container.encode("input_image", forKey: .type)
                try container.encode(imageURL, forKey: .imageURL)
                try container.encode(detail, forKey: .detail)
            }
        }
    }

    struct Reasoning: Encodable { let effort: String }
    struct Text: Encodable { let verbosity: String }
}

private struct ResponsesResponse: Decodable {
    let status: String?
    let output: [Output]
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case status, output
        case incompleteDetails = "incomplete_details"
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct Output: Decodable {
        let type: String
        let content: [Content]?
    }

    struct Content: Decodable {
        let type: String
        let text: String?
    }
}

private struct OpenAIErrorResponse: Decodable {
    let error: APIError
    struct APIError: Decodable { let message: String }
}
