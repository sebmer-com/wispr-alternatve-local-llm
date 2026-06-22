import Foundation

final class AzureOpenAICommandLLMClient: CommandLLMClient, @unchecked Sendable {
    private let config: LocalLLMConfig
    private let session: URLSession

    init(config: LocalLLMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var displayName: String {
        switch config.provider {
        case .azureOpenAI:
            return "Azure OpenAI \(config.model)"
        case .openAICompatible:
            return "OpenAI-compatible \(config.model)"
        case .mlx:
            return "local MLX \(config.model)"
        }
    }

    var requiresWarmUp: Bool {
        false
    }

    func warmUp(systemPrompt: String) async throws {}

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        let maxAttempts = max(1, config.maxRetries + 1)
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await completeOnce(systemPrompt: systemPrompt, userPrompt: userPrompt)
            } catch {
                lastError = error
                guard attempt < maxAttempts, shouldRetry(error) else {
                    throw error
                }
                log("\(displayName) command request failed on attempt \(attempt); retrying: \(error)")
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw lastError ?? CliError.invalidValue("\(displayName) command request failed")
    }

    private func completeOnce(systemPrompt: String, userPrompt: String) async throws -> String {
        guard let url = config.chatCompletionsURL else {
            throw CliError.invalidValue("local_llm.endpoint or local_llm.base_url must be a valid chat completions URL")
        }
        let apiKey = config.resolvedAPIKey
        let apiKeyEnv = config.apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKeyEnv.isEmpty || !apiKey.isEmpty else {
            return try await send(
                requestTo: url,
                apiKey: "",
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        }
        guard !apiKey.isEmpty else {
            throw CliError.invalidValue(
                "\(apiKeyEnv) must be set in the environment or local_llm.dotenv_file"
            )
        }
        return try await send(
            requestTo: url,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }

    private func send(
        requestTo url: URL,
        apiKey: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = min(config.requestTimeoutSeconds, config.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if config.provider == .azureOpenAI, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: config.model,
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userPrompt),
                ],
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                stream: false
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CliError.invalidValue("\(displayName) command request returned a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AzureOpenAICommandError.http(
                statusCode: httpResponse.statusCode,
                message: errorSummary(from: data)
            )
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        return decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func errorSummary(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ChatCompletionErrorResponse.self, from: data) {
            return decoded.error.message
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(500))
        }
        return "empty response body"
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let azureError = error as? AzureOpenAICommandError {
            return azureError.isRetryable
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }
}

private enum AzureOpenAICommandError: Error, CustomStringConvertible {
    case http(statusCode: Int, message: String)

    var isRetryable: Bool {
        switch self {
        case let .http(statusCode, _):
            return statusCode == 429 || (500..<600).contains(statusCode)
        }
    }

    var description: String {
        switch self {
        case let .http(statusCode, message):
            return "Chat completions command request failed with HTTP \(statusCode): \(message)"
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatResponseMessage
    }
}

private struct ChatResponseMessage: Decodable {
    let role: String?
    let content: String?
}

private struct ChatCompletionErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
    }
}
