import Foundation

enum AppInfo {
    static let version = "0.2.3"
}

struct AppConfig: Codable {
    var promptConfigFile = "promptConfig.json"
    var textReplacementsFile = "textReplacements.json"
    var debug = DebugConfig()
    var asr = AsrConfig()
    var audioInput = AudioInputConfig()
    var hotkeys = HotkeysConfig()
    var paste = PasteConfig()
    var recordings = RecordingsConfig()
    var dump = DumpConfig()
    var continuousDump = ContinuousDumpConfig()
    var audioDucking = AudioDuckingConfig()
    var hermesAgent = HermesAgentConfig()
    var llmOutput = LLMOutputConfig()
    var bluetoothKeyboard = BluetoothKeyboardConfig()
    var skills = SkillsConfig()
    var localLLM = LocalLLMConfig()
    var prompts = PromptConfig()
    var textReplacements = TextReplacementConfig()

    enum CodingKeys: String, CodingKey {
        case promptConfigFile = "prompt_config_file"
        case textReplacementsFile = "text_replacements_file"
        case debug
        case asr
        case audioInput = "audio_input"
        case hotkeys
        case paste
        case recordings
        case dump
        case continuousDump = "continuous_dump"
        case audioDucking = "audio_ducking"
        case hermesAgent = "hermes_agent"
        case llmOutput = "llm_output"
        case bluetoothKeyboard = "bluetooth_keyboard"
        case skills
        case localLLM = "local_llm"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptConfigFile = try container.decodeIfPresent(String.self, forKey: .promptConfigFile) ?? promptConfigFile
        textReplacementsFile = try container.decodeIfPresent(
            String.self,
            forKey: .textReplacementsFile
        ) ?? textReplacementsFile
        debug = try container.decodeIfPresent(DebugConfig.self, forKey: .debug) ?? DebugConfig()
        asr = try container.decodeIfPresent(AsrConfig.self, forKey: .asr) ?? AsrConfig()
        audioInput = try container.decodeIfPresent(AudioInputConfig.self, forKey: .audioInput) ?? AudioInputConfig()
        hotkeys = try container.decodeIfPresent(HotkeysConfig.self, forKey: .hotkeys) ?? HotkeysConfig()
        paste = try container.decodeIfPresent(PasteConfig.self, forKey: .paste) ?? PasteConfig()
        recordings = try container.decodeIfPresent(RecordingsConfig.self, forKey: .recordings) ?? RecordingsConfig()
        dump = try container.decodeIfPresent(DumpConfig.self, forKey: .dump) ?? DumpConfig()
        continuousDump = try container.decodeIfPresent(
            ContinuousDumpConfig.self,
            forKey: .continuousDump
        ) ?? ContinuousDumpConfig()
        audioDucking = try container.decodeIfPresent(AudioDuckingConfig.self, forKey: .audioDucking) ?? AudioDuckingConfig()
        hermesAgent = try container.decodeIfPresent(HermesAgentConfig.self, forKey: .hermesAgent) ?? HermesAgentConfig()
        llmOutput = try container.decodeIfPresent(LLMOutputConfig.self, forKey: .llmOutput) ?? LLMOutputConfig()
        bluetoothKeyboard = try container.decodeIfPresent(
            BluetoothKeyboardConfig.self,
            forKey: .bluetoothKeyboard
        ) ?? BluetoothKeyboardConfig()
        skills = try container.decodeIfPresent(SkillsConfig.self, forKey: .skills) ?? SkillsConfig()
        localLLM = try container.decodeIfPresent(LocalLLMConfig.self, forKey: .localLLM) ?? LocalLLMConfig()
    }

    static func load(from url: URL?) throws -> AppConfig {
        let configURL = url ?? defaultURL
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            var config = AppConfig()
            config.prompts = try PromptConfig.load(
                preferredURL: config.promptConfigURL(relativeTo: configURL),
                fallbackURL: Self.repositoryPromptConfigURL
            )
            config.localLLM.resolveDotEnvFiles(relativeTo: configURL)
            config.textReplacements = try TextReplacementConfig.load(
                preferredURL: config.textReplacementsURL(relativeTo: configURL),
                fallbackURL: Self.repositoryTextReplacementsURL
            )
            return config
        }

        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        var config = try decoder.decode(AppConfig.self, from: data)
        config.prompts = try PromptConfig.load(
            preferredURL: config.promptConfigURL(relativeTo: configURL),
            fallbackURL: Self.repositoryPromptConfigURL
        )
        config.localLLM.resolveDotEnvFiles(relativeTo: configURL)
        config.textReplacements = try TextReplacementConfig.load(
            preferredURL: config.textReplacementsURL(relativeTo: configURL),
            fallbackURL: Self.repositoryTextReplacementsURL
        )
        return config
    }

    static var defaultURL: URL {
        URL(fileURLWithPath: "~/.config/fluid-push-to-talk/config.json".expandingTilde)
    }

    static var repositoryPromptConfigURL: URL {
        repositoryRootURL.appendingPathComponent("config/promptConfig.json")
    }

    static var repositoryTextReplacementsURL: URL {
        repositoryRootURL.appendingPathComponent("config/textReplacements.json")
    }

    static var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func promptConfigURL(relativeTo configURL: URL) -> URL {
        configFileURL(promptConfigFile, relativeTo: configURL)
    }

    private func textReplacementsURL(relativeTo configURL: URL) -> URL {
        configFileURL(textReplacementsFile, relativeTo: configURL)
    }

    private func configFileURL(_ path: String, relativeTo configURL: URL) -> URL {
        let expandedPath = path.expandingTilde
        if expandedPath.isAbsolutePath {
            return URL(fileURLWithPath: expandedPath)
        }
        return configURL.deletingLastPathComponent().appendingPathComponent(expandedPath)
    }
}

struct DebugConfig: Codable {
    var enabled = false
    var logLLMRequests = false

    enum CodingKeys: String, CodingKey {
        case enabled
        case logLLMRequests = "log_llm_requests"
    }
}

struct AsrConfig: Codable {
    var modelVersion = "v3"
    var language = "de"

    enum CodingKeys: String, CodingKey {
        case modelVersion = "model_version"
        case language
    }
}

struct AudioInputConfig: Codable {
    var deviceUID = ""
    var deviceName = ""

    enum CodingKeys: String, CodingKey {
        case deviceUID = "device_uid"
        case deviceName = "device_name"
    }
}

struct PasteConfig: Codable {
    var enabled = true
    var restoreClipboard = true
    var pasteDelay: TimeInterval = 0.1
    var restoreClipboardDelay: TimeInterval = 0.5

    enum CodingKeys: String, CodingKey {
        case enabled
        case restoreClipboard = "restore_clipboard"
        case pasteDelay = "paste_delay"
        case restoreClipboardDelay = "restore_clipboard_delay"
    }
}

struct RecordingsConfig: Codable {
    var save = false
    var outputDir = "recordings-fluid"

    enum CodingKeys: String, CodingKey {
        case save
        case outputDir = "output_dir"
    }

    var outputURL: URL {
        URL(fileURLWithPath: outputDir.expandingTilde, isDirectory: true)
    }
}

struct DumpConfig: Codable {
    var enabled = true
    var markdownFile = "~/Documents/Obsidian/Daily Notes/YYYY-MM-DD.md"
    var append = true
    var includeTimestamp = true

    enum CodingKeys: String, CodingKey {
        case enabled
        case markdownFile = "markdown_file"
        case append
        case includeTimestamp = "include_timestamp"
    }

    var markdownURL: URL {
        URL(fileURLWithPath: resolvedMarkdownFile.expandingTilde)
    }

    private var resolvedMarkdownFile: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dailyNoteName = formatter.string(from: Date())
        return markdownFile
            .replacingOccurrences(of: "YYYY-MM-DD", with: dailyNoteName)
            .replacingOccurrences(of: "yyyy-MM-dd", with: dailyNoteName)
    }
}

struct ContinuousDumpConfig: Codable {
    var enabled = true

    enum CodingKeys: String, CodingKey {
        case enabled
    }
}

struct AudioDuckingConfig: Codable {
    var enabled = true

    enum CodingKeys: String, CodingKey {
        case enabled
    }
}

struct HermesAgentConfig: Codable {
    var enabled = true
    var executable = "hermes"
    var sessionName = "local-audio-voice-agent"
    var workdir = "~"
    var foregroundTerminal = true
    var timeoutSeconds: TimeInterval = 900

    enum CodingKeys: String, CodingKey {
        case enabled
        case executable
        case sessionName = "session_name"
        case workdir
        case foregroundTerminal = "foreground_terminal"
        case timeoutSeconds = "timeout_seconds"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? executable
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? sessionName
        workdir = try container.decodeIfPresent(String.self, forKey: .workdir) ?? workdir
        foregroundTerminal = try container.decodeIfPresent(Bool.self, forKey: .foregroundTerminal) ?? foregroundTerminal
        timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? timeoutSeconds
    }

    var resolvedWorkdir: String? {
        let trimmed = workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.expandingTilde
    }
}

enum LLMOutputMethod: String, Codable {
    case clipboard
    case dump
    case bluetoothKeyboard = "bluetooth-keyboard"

    var displayName: String {
        rawValue
    }

    var locationDisplayName: String {
        switch self {
        case .clipboard, .dump:
            return "LOKAL"
        case .bluetoothKeyboard:
            return "BLUETOOTH"
        }
    }

    var destinationDisplayName: String {
        switch self {
        case .clipboard:
            return "Zwischenablage"
        case .dump:
            return "Markdown-Dump"
        case .bluetoothKeyboard:
            return "ESP32-Tastatur"
        }
    }
}

struct LLMOutputConfig: Codable {
    var paste = LLMOutputMethod.clipboard
    var dump = LLMOutputMethod.dump
    var bluetooth = LLMOutputMethod.clipboard

    enum CodingKeys: String, CodingKey {
        case paste
        case dump
        case bluetooth
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paste = try container.decodeIfPresent(LLMOutputMethod.self, forKey: .paste) ?? paste
        dump = try container.decodeIfPresent(LLMOutputMethod.self, forKey: .dump) ?? dump
        bluetooth = try container.decodeIfPresent(LLMOutputMethod.self, forKey: .bluetooth) ?? bluetooth
    }

    func method(for action: HotkeyAction) -> LLMOutputMethod {
        switch action {
        case .paste:
            return paste
        case .dump:
            return dump
        case .bluetooth:
            return bluetooth
        }
    }
}

struct BluetoothKeyboardConfig: Codable {
    var port: String?
    var chunkSize = 32

    enum CodingKeys: String, CodingKey {
        case port
        case chunkSize = "chunk_size"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(String.self, forKey: .port)
        chunkSize = try container.decodeIfPresent(Int.self, forKey: .chunkSize) ?? chunkSize
    }

    var resolvedPort: String? {
        guard let port else {
            return nil
        }
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.expandingTilde
    }
}

struct LocalLLMConfig: Codable {
    enum Provider: String, Codable {
        case mlx
        case azureOpenAI = "azure_openai"
        case openAICompatible = "openai_compatible"
    }

    var enabled = true
    var commandGenerationEnabled = true
    var provider = Provider.mlx
    var mlxRun = "mlx-run"
    var llmTool = "llm-tool"
    var download = "~/Library/Application Support/FluidPushToTalk/Models"
    var model = "prism-ml/Ternary-Bonsai-8B-mlx-2bit"
    var endpoint = ""
    var baseURL = ""
    var apiKeyEnv = "OPENAI_API_KEY"
    var dotenvFile = ".env"
    private var dotenvURLs: [URL] = []
    var temperature = 0.0
    var maxTokens = 96
    var cacheSize = 4096
    var memorySize = 4096
    var timeoutSeconds: TimeInterval = 30
    var requestTimeoutSeconds: TimeInterval = 8
    var maxRetries = 1

    enum CodingKeys: String, CodingKey {
        case enabled
        case commandGenerationEnabled = "command_generation_enabled"
        case provider
        case mlxRun = "mlx_run"
        case llmTool = "llm_tool"
        case download
        case model
        case endpoint
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
        case dotenvFile = "dotenv_file"
        case temperature
        case maxTokens = "max_tokens"
        case cacheSize = "cache_size"
        case memorySize = "memory_size"
        case timeoutSeconds = "timeout_seconds"
        case requestTimeoutSeconds = "request_timeout_seconds"
        case maxRetries = "max_retries"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        commandGenerationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .commandGenerationEnabled
        ) ?? commandGenerationEnabled
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? provider
        mlxRun = try container.decodeIfPresent(String.self, forKey: .mlxRun) ?? mlxRun
        llmTool = try container.decodeIfPresent(String.self, forKey: .llmTool) ?? llmTool
        download = try container.decodeIfPresent(String.self, forKey: .download) ?? download
        if let decodedModel = try container.decodeIfPresent(String.self, forKey: .model),
           !decodedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model = decodedModel
        }
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        apiKeyEnv = try container.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? apiKeyEnv
        dotenvFile = try container.decodeIfPresent(String.self, forKey: .dotenvFile) ?? dotenvFile
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? maxTokens
        cacheSize = try container.decodeIfPresent(Int.self, forKey: .cacheSize) ?? cacheSize
        memorySize = try container.decodeIfPresent(Int.self, forKey: .memorySize) ?? memorySize
        timeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds) ?? timeoutSeconds
        requestTimeoutSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .requestTimeoutSeconds
        ) ?? requestTimeoutSeconds
        maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries) ?? maxRetries
    }

    var mlxRunURL: URL {
        URL(fileURLWithPath: mlxRun.expandingTilde)
    }

    var canGenerateCommands: Bool {
        enabled && commandGenerationEnabled
    }

    var llmToolURL: URL? {
        let path = llmTool.expandingTilde
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    var chatCompletionsURL: URL? {
        let rawURL: String
        switch provider {
        case .openAICompatible:
            rawURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? endpoint : baseURL
        case .azureOpenAI, .mlx:
            rawURL = endpoint
        }

        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard var components = URLComponents(string: trimmed) else {
            return nil
        }
        if !components.path.hasSuffix("/chat/completions") {
            let normalizedPath = components.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = normalizedPath.isEmpty
                ? "/chat/completions"
                : "/\(normalizedPath)/chat/completions"
        }
        return components.url
    }

    var resolvedAPIKey: String {
        let keyName = apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyName.isEmpty else {
            return ""
        }
        if let environmentValue = ProcessInfo.processInfo.environment[keyName]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        for dotenvURL in dotenvURLs {
            if let value = DotEnvFile.loadValue(named: keyName, from: dotenvURL),
               !value.isEmpty {
                return value
            }
        }
        return ""
    }

    mutating func resolveDotEnvFiles(relativeTo configURL: URL) {
        let configuredPath = dotenvFile.expandingTilde
        let configuredURL: URL
        if configuredPath.isAbsolutePath {
            configuredURL = URL(fileURLWithPath: configuredPath)
        } else {
            configuredURL = configURL.deletingLastPathComponent().appendingPathComponent(configuredPath)
        }
        dotenvURLs = uniqueURLs([
            configuredURL,
            AppConfig.repositoryRootURL.appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
        ])
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }
}

enum DotEnvFile {
    static func loadValue(named name: String, from url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == name else {
                continue
            }
            return cleanValue(String(parts[1]))
        }
        return nil
    }

    private static func cleanValue(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           let first = trimmed.first,
           let last = trimmed.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
