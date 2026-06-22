import Foundation

final class LocalLLMReadinessMonitor: @unchecked Sendable {
    private let config: AppConfig
    private let llmClient: CommandLLMClient
    private let lock = NSLock()
    private var ready = false
    private var warming = false

    init(config: AppConfig, llmClient: CommandLLMClient) {
        self.config = config
        self.llmClient = llmClient
    }

    func waitUntilReady() async {
        await warmUp(reason: "startup")
    }

    func warmUpInBackground(reason: String) {
        Task.detached(priority: .utility) {
            await self.warmUp(reason: reason)
        }
    }

    private func warmUp(reason: String) async {
        guard config.localLLM.canGenerateCommands else {
            log("command LLM disabled")
            return
        }
        let apiKeyEnv = config.localLLM.apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.localLLM.provider != .mlx,
           !apiKeyEnv.isEmpty,
           config.localLLM.resolvedAPIKey.isEmpty {
            log("command LLM missing \(apiKeyEnv); dictation stays available")
            return
        }

        let shouldWarm = lock.withLock {
            guard !ready, !warming else {
                return false
            }
            warming = true
            return true
        }
        guard shouldWarm else {
            return
        }
        defer {
            lock.withLock {
                warming = false
            }
        }

        log("command LLM configured: \(llmClient.displayName)")
        guard llmClient.requiresWarmUp else {
            lock.withLock {
                ready = true
            }
            log("command LLM ready: \(llmClient.displayName)")
            return
        }

        if let llmToolURL = config.localLLM.llmToolURL,
           FileManager.default.isExecutableFile(atPath: llmToolURL.path) {
            log("using llm-tool directly at \(llmToolURL.path)")
        } else {
            let mlxRunURL = config.localLLM.mlxRunURL
            log("using mlx-run at \(mlxRunURL.path)")
            guard FileManager.default.isExecutableFile(atPath: mlxRunURL.path) else {
                log("local MLX llm-tool not ready: llm-tool and mlx-run are missing or not executable")
                return
            }
        }

        do {
            let startedAt = Date()
            log("loading local MLX llm-tool model once for low-latency requests (\(reason))...")
            try await llmClient.warmUp(systemPrompt: config.prompts.coreCommand.system)
            lock.withLock {
                ready = true
            }
            log(
                "local MLX llm-tool ready: \(config.localLLM.model) (\(formatSeconds(Date().timeIntervalSince(startedAt))))"
            )
        } catch {
            log("local MLX llm-tool not ready: \(error)")
        }
    }
}

enum LLMDebugLogger {
    static func logPrompt(_ prompt: String, label: String, config: AppConfig) {
        guard config.debug.enabled || config.debug.logLLMRequests else {
            return
        }
        log(
            """
            command LLM prompt for \(label):
            \(prompt)
            """
        )
    }
}
