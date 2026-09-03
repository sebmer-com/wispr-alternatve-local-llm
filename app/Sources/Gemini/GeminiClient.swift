import Foundation

final class GeminiClient: CommandLLMClient, @unchecked Sendable {
    static let model = "gemini-3.5-flash"
    static let temperature = 0.2
    static let maxOutputTokens = 256
    static let maximumImages = 5
    static let userAgent = "fluid-push-to-talk/0.2.3"
    static let apiKeyEnvironmentName = "GEMINI_API_KEY"

    static var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
    }

    private let apiKey: String
    private let requestURL: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let maxRetries: Int
    private let logger: @Sendable (String) -> Void

    var displayName: String {
        "Gemini \(Self.model)"
    }

    init(
        apiKey: String,
        endpoint: URL = GeminiClient.endpoint,
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
            throw GeminiError.tooManyImages(maximum: Self.maximumImages)
        }
        guard !apiKey.isEmpty else {
            throw GeminiError.missingAPIKey
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
            provider: "gemini",
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
                provider: "gemini",
                attempt: attempt,
                maximumAttempts: maximumAttempts
            )
            let attemptStartedAt = Date()
            var responseMetadata: CommandHTTPResponseMetadata?
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GeminiError.nonHTTPResponse
                }
                responseMetadata = CommandRequestDiagnostics.responseMetadata(data: data, response: httpResponse)
                let content = try decodeResponse(data: data, response: httpResponse)
                CommandRequestDiagnostics.logAttemptResult(
                    logger: logger,
                    requestID: requestID,
                    provider: "gemini",
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
                    provider: "gemini",
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
                        provider: "gemini",
                        error: error
                    )
                    throw error
                }
                CommandRequestDiagnostics.logRetry(
                    logger: logger,
                    requestID: requestID,
                    provider: "gemini",
                    reason: retryReason
                )
            }
        }
        preconditionFailure("Gemini request attempt loop exhausted unexpectedly")
    }

    private func makeRequest(
        systemPrompt: String,
        userPrompt: String,
        attachments: [CommandImageAttachment]
    ) throws -> URLRequest {
        var parts: [GenerateContentRequest.Part] = [.text(userPrompt)]
        parts.append(contentsOf: attachments.map { attachment in
            .inlineData(mimeType: attachment.mimeType, data: Self.rawBase64(from: attachment.dataURL))
        })
        let payload = GenerateContentRequest(
            systemInstruction: .init(parts: [.init(text: systemPrompt)]),
            contents: [.init(role: "user", parts: parts)],
            generationConfig: .init(temperature: Self.temperature, maxOutputTokens: Self.maxOutputTokens)
        )

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private static func rawBase64(from dataURL: String) -> String {
        guard let comma = dataURL.firstIndex(of: ",") else {
            return dataURL
        }
        return String(dataURL[dataURL.index(after: comma)...])
    }

    private func decodeResponse(data: Data, response httpResponse: HTTPURLResponse) throws -> String {
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GeminiError.http(
                statusCode: httpResponse.statusCode,
                message: errorSummary(from: data)
            )
        }

        let payload: GenerateContentResponse
        do {
            payload = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            throw GeminiError.invalidResponse
        }

        if let blockReason = payload.promptFeedback?.blockReason {
            throw GeminiError.blocked(reason: blockReason)
        }

        guard let candidate = payload.candidates?.first else {
            throw GeminiError.emptyResponse
        }

        let text = (candidate.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.isEmpty else {
            return text
        }

        let finishReason = candidate.finishReason ?? "UNKNOWN"
        guard finishReason == "STOP" || finishReason == "MAX_TOKENS" else {
            throw GeminiError.blocked(reason: finishReason)
        }
        throw GeminiError.emptyResponse
    }

    private func retryReason(for error: Error) -> String? {
        if case let GeminiError.http(statusCode, _) = error {
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
        if let payload = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data),
           !payload.error.message.isEmpty {
            return CommandRequestDiagnostics.sanitizedProviderMessage(payload.error.message)
        }
        return "request failed"
    }

}

enum GeminiError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case tooManyImages(maximum: Int)
    case nonHTTPResponse
    case http(statusCode: Int, message: String)
    case invalidResponse
    case blocked(reason: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "GEMINI_API_KEY is not configured"
        case let .tooManyImages(maximum): return "Gemini accepts at most \(maximum) screenshots per command"
        case .nonHTTPResponse: return "Gemini returned a non-HTTP response"
        case let .http(statusCode, message):
            return "Gemini generateContent request failed with HTTP \(statusCode): \(message)"
        case .invalidResponse: return "Gemini returned an invalid generateContent payload"
        case let .blocked(reason): return "Gemini blocked the response (\(reason))"
        case .emptyResponse: return "Gemini returned an empty response"
        }
    }
}

private struct GenerateContentRequest: Encodable {
    let systemInstruction: SystemInstruction
    let contents: [Content]
    let generationConfig: GenerationConfig

    struct SystemInstruction: Encodable {
        let parts: [TextPart]
    }

    struct TextPart: Encodable {
        let text: String
    }

    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
    }

    enum Part: Encodable {
        case text(String)
        case inlineData(mimeType: String, data: String)

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData
        }

        enum InlineDataCodingKeys: String, CodingKey {
            case mimeType
            case data
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode(text, forKey: .text)
            case let .inlineData(mimeType, data):
                var inlineContainer = container.nestedContainer(keyedBy: InlineDataCodingKeys.self, forKey: .inlineData)
                try inlineContainer.encode(mimeType, forKey: .mimeType)
                try inlineContainer.encode(data, forKey: .data)
            }
        }
    }
}

private struct GenerateContentResponse: Decodable {
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }

    struct Content: Decodable {
        let parts: [Part]?
    }

    struct Part: Decodable {
        let text: String?
    }

    struct PromptFeedback: Decodable {
        let blockReason: String?
    }
}

private struct GeminiErrorResponse: Decodable {
    let error: APIError
    struct APIError: Decodable { let message: String }
}
