import Foundation

enum AppInfo {
    static let version = "0.2.3"
}

enum CommandProvider: String, Codable {
    case openAI = "openai"
    case cerebras
    case gemini

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .cerebras: return "Cerebras"
        case .gemini: return "Gemini"
        }
    }

    var model: String {
        switch self {
        case .openAI: return OpenAISecrets.model
        case .cerebras: return CerebrasSecrets.model
        case .gemini: return GeminiSecrets.model
        }
    }

    var apiKeyEnvironmentName: String {
        switch self {
        case .openAI: return OpenAISecrets.apiKeyEnvironmentName
        case .cerebras: return CerebrasSecrets.apiKeyEnvironmentName
        case .gemini: return GeminiSecrets.apiKeyEnvironmentName
        }
    }

    func resolveAPIKey(configURL: URL) -> String {
        ProviderSecrets.resolveAPIKey(named: apiKeyEnvironmentName, configURL: configURL)
    }
}

enum ControlOptionMode: String, Codable {
    case dump
    case hermes

    var displayName: String {
        switch self {
        case .dump: return "Markdown Dump"
        case .hermes: return "Hermes Agent"
        }
    }
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
    var commandProvider = CommandProvider.openAI
    var controlOptionMode = ControlOptionMode.dump
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
        case commandProvider = "command_provider"
        case controlOptionMode = "control_option_mode"
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
        commandProvider = try container.decodeIfPresent(
            CommandProvider.self,
            forKey: .commandProvider
        ) ?? .openAI
        controlOptionMode = try container.decodeIfPresent(
            ControlOptionMode.self,
            forKey: .controlOptionMode
        ) ?? .dump
    }

    static func load(from url: URL?) throws -> AppConfig {
        let configURL = url ?? defaultURL
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            var config = AppConfig()
            config.prompts = try PromptConfig.load(
                preferredURL: config.promptConfigURL(relativeTo: configURL),
                fallbackURL: Self.repositoryPromptConfigURL
            )
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

    enum CodingKeys: String, CodingKey {
        case enabled
    }
}

struct AsrConfig: Codable {
    var modelVersion = "v3"
    var language = "system"

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
    var executable = "hermes"
    var sessionName = "local-audio-voice-agent"
    var workdir = "~"
    var foregroundTerminal = true
    var timeoutSeconds: TimeInterval = 900

    enum CodingKeys: String, CodingKey {
        case executable
        case sessionName = "session_name"
        case workdir
        case foregroundTerminal = "foreground_terminal"
        case timeoutSeconds = "timeout_seconds"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

enum OpenAISecrets {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let model = "gpt-5.6-luna"
    static let reasoningEffort = "low"
    static let imageDetail = "low"
    static let apiKeyEnvironmentName = "OPENAI_API_KEY"

    static func resolveAPIKey(configURL: URL) -> String {
        ProviderSecrets.resolveAPIKey(named: apiKeyEnvironmentName, configURL: configURL)
    }
}

enum CerebrasSecrets {
    static let model = "gemma-4-31b"
    static let apiKeyEnvironmentName = "CEREBRAS_API_KEY"

    static func resolveAPIKey(configURL: URL) -> String {
        ProviderSecrets.resolveAPIKey(named: apiKeyEnvironmentName, configURL: configURL)
    }
}

enum GeminiSecrets {
    static let model = "gemini-3.5-flash"
    static let apiKeyEnvironmentName = "GEMINI_API_KEY"

    static func resolveAPIKey(configURL: URL) -> String {
        ProviderSecrets.resolveAPIKey(named: apiKeyEnvironmentName, configURL: configURL)
    }
}

private enum ProviderSecrets {
    static func resolveAPIKey(named name: String, configURL: URL) -> String {
        if let environmentValue = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        return DotEnvFile.loadValue(
            named: name,
            from: configURL.deletingLastPathComponent().appendingPathComponent(".env")
        ) ?? ""
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
