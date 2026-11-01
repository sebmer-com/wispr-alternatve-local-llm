import Darwin
import Foundation

/// A single completion, never an agent loop. Credentials remain entirely in the bridge.
final class HermesCommandClient: CommandLLMClient, Sendable {
    private let provider: String
    private let model: String
    private let timeoutSeconds: TimeInterval
    private let launcherURL: URL

    var displayName: String { "Hermes \(provider) \(model)" }

    init(
        provider: String,
        model: String,
        timeoutSeconds: TimeInterval = 60,
        launcherURL: URL = AppConfig.repositoryRootURL.appendingPathComponent("scripts/run-hermes-bridge.sh")
    ) {
        self.provider = provider
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.launcherURL = launcherURL
    }

    func complete(systemPrompt: String, userPrompt: String, imageURLs: [URL] = []) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try Self.validate(provider: provider, model: model, timeout: timeoutSeconds)
                    try Self.validateImages(imageURLs)
                    let request = BridgeRequest(action: "complete", provider: provider, model: model,
                        system_prompt: systemPrompt, user_prompt: userPrompt,
                        images: imageURLs.map(\.path), timeout_seconds: timeoutSeconds)
                    let payload = try JSONEncoder().encode(request)
                    let requestID = UUID().uuidString
                    // Counts only: no prompts, request bodies, credentials, or bridge stderr.
                    log("command_request request_id=\(requestID) provider=\(provider) auth=hermes model=\(model) prompt_chars=\(systemPrompt.count + userPrompt.count) image_count=\(imageURLs.count) payload_bytes=\(payload.count) timeout_seconds=\(timeoutSeconds)")
                    let response = try Self.exchange(payload, launcherURL: launcherURL, timeout: timeoutSeconds)
                    guard let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                        throw HermesCommandError.invalidResponse
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous for CLI/startup diagnostics; callers must not run this on the UI queue.
    static func doctor(
        provider: String,
        model: String,
        launcherURL: URL = AppConfig.repositoryRootURL.appendingPathComponent("scripts/run-hermes-bridge.sh"),
        timeoutSeconds: TimeInterval = 30
    ) -> (passed: Bool, detail: String) {
        do {
            try validate(provider: provider, model: model, timeout: timeoutSeconds)
            let request = BridgeRequest(action: "doctor", provider: provider, model: model,
                system_prompt: "", user_prompt: "", images: [], timeout_seconds: timeoutSeconds)
            let response = try exchange(JSONEncoder().encode(request), launcherURL: launcherURL, timeout: timeoutSeconds)
            guard let detail = response.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
                throw HermesCommandError.invalidResponse
            }
            return (true, detail)
        } catch {
            return (false, (error as? HermesCommandError)?.localizedDescription ?? HermesCommandError.transport.localizedDescription)
        }
    }

    private static func validate(provider: String, model: String, timeout: TimeInterval) throws {
        guard ["openai-codex", "anthropic"].contains(provider), !model.isEmpty,
              model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$"#, options: .regularExpression) != nil,
              timeout.isFinite, timeout > 0 else { throw HermesCommandError.invalidConfiguration }
    }

    private static func validateImages(_ urls: [URL]) throws {
        guard urls.count <= 5 else { throw HermesCommandError.tooManyImages }
        for url in urls {
            do {
                guard url.isFileURL, url.pathExtension.lowercased() == "png" else { throw HermesCommandError.invalidImage }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw HermesCommandError.invalidImage }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard try handle.read(upToCount: 8) == Data([137,80,78,71,13,10,26,10]) else { throw HermesCommandError.invalidImage }
            } catch { throw HermesCommandError.invalidImage }
        }
    }

    /// Nonblocking multiplexing drains both output pipes while feeding stdin. No reader can
    /// deadlock behind a full sibling pipe, and an inherited pipe cannot extend the deadline.
    private static func exchange(_ payload: Data, launcherURL: URL, timeout: TimeInterval) throws -> BridgeResponse {
        guard launcherURL.isFileURL else { throw HermesCommandError.invalidConfiguration }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcherURL.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        defer {
            for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                           output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
        }
        do { try process.run() } catch { throw HermesCommandError.transport }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit() // Reap even on overflow, timeout, malformed output, or broken stdin.
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let stdinFD = input.fileHandleForWriting.fileDescriptor
        let stdoutFD = output.fileHandleForReading.fileDescriptor
        let stderrFD = errors.fileHandleForReading.fileDescriptor
        for fd in [stdinFD, stdoutFD, stderrFD] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw HermesCommandError.transport }
        }
        // A bridge exiting early must not deliver SIGPIPE to the application.
        guard fcntl(stdinFD, F_SETNOSIGPIPE, 1) != -1 else { throw HermesCommandError.transport }
        var written = 0
        var inputOpen = true
        var stdout = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HermesCommandError.timeout }
            try drain(stdoutFD, into: &stdout, keep: true)
            var discarded = Data()
            try drain(stderrFD, into: &discarded, keep: false)
            if !process.isRunning {
                // Consume the last bytes queued before exit, without waiting on descendants.
                try drain(stdoutFD, into: &stdout, keep: true)
                break
            }
            if inputOpen {
                if written < payload.count {
                    let count = payload.withUnsafeBytes { bytes in
                        Darwin.write(stdinFD, bytes.baseAddress!.advanced(by: written), min(65_536, payload.count - written))
                    }
                    if count > 0 { written += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { throw HermesCommandError.transport }
                }
                if written == payload.count {
                    try? input.fileHandleForWriting.close()
                    inputOpen = false
                }
            }
            usleep(5_000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HermesCommandError.bridgeFailed }
        guard let response = try? JSONDecoder().decode(BridgeResponse.self, from: stdout) else { throw HermesCommandError.invalidResponse }
        guard response.ok else { throw HermesCommandError.bridgeFailed }
        return response
    }

    private static func drain(_ fd: Int32, into data: inout Data, keep: Bool) throws {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // Bound work per iteration, including hostile endless stderr, so deadlines are checked.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if keep {
                    guard data.count + count <= 1_048_576 else { throw HermesCommandError.outputLimit }
                    data.append(buffer, count: count)
                }
            } else if count == 0 || errno == EAGAIN { return }
            else if errno != EINTR { throw HermesCommandError.transport }
        }
    }
}

private struct BridgeRequest: Encodable {
    let action: String
    let provider: String
    let model: String
    let system_prompt: String
    let user_prompt: String
    let images: [String]
    let timeout_seconds: TimeInterval
    let reasoning_effort = "low"
}
private struct BridgeResponse: Decodable {
    let ok: Bool
    let text: String?
    let detail: String?
}

enum HermesCommandError: Error, LocalizedError, Equatable {
    case invalidConfiguration, tooManyImages, invalidImage, transport, timeout, outputLimit, invalidResponse, bridgeFailed
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Hermes command configuration is invalid"
        case .tooManyImages: return "Hermes accepts at most five screenshots per command"
        case .invalidImage: return "Hermes requires existing regular PNG screenshot files"
        case .transport: return "Hermes command bridge transport failed"
        case .timeout: return "Hermes command bridge timed out"
        case .outputLimit: return "Hermes command bridge exceeded the response size limit"
        case .invalidResponse: return "Hermes command bridge returned an invalid or empty response"
        case .bridgeFailed: return "Hermes command bridge failed; check subscription authentication with doctor"
        }
    }
}
