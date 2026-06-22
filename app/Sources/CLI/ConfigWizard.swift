import ApplicationServices
import Darwin
import Foundation

enum RuntimeCommand {
    case run
    case setup
    case configMenu
    case configShow
    case configDoctor
    case configReset
}

enum ConfigWizard {
    private static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    private static let defaultOpenAIModel = "gpt-5.4-mini"
    private static let defaultOpenAIAPIKeyEnv = "OPENAI_API_KEY"
    private static let defaultAzureEndpoint = "https://dparnold-2501-resource.services.ai.azure.com/openai/v1/chat/completions"

    static func runSetup(configPath: URL?) throws {
        let paths = ConfigPaths(configPath: configPath)
        let input = WizardInput()
        var config = try loadWizardBaseConfig(paths: paths)

        printHeader("Local Audio Setup")
        let profile = input.choose(
            prompt: "Profil auswaehlen",
            options: [
                "Schnellstart: OpenAI-kompatibel + lokale Paste + Markdown + Bluetooth aus",
                "Power User: alles konfigurieren",
                "Minimal: nur Diktat/Paste, Command-LLM aus",
            ],
            defaultIndex: 0
        )

        var secretUpdates: [String: String] = [:]
        switch profile {
        case 0:
            applyQuickStart(to: &config)
            configureRemoteToken(config: &config, input: input, secretUpdates: &secretUpdates)
            configureHermesAgent(config: &config, input: input)
            configureDailyNote(config: &config, input: input)
        case 1:
            configureCommandLLM(config: &config, input: input, secretUpdates: &secretUpdates)
            configureShortcuts(config: &config, input: input)
            configureHermesAgent(config: &config, input: input)
            configureBluetooth(config: &config, input: input)
            configureOutputs(config: &config, input: input)
            configureDailyNote(config: &config, input: input)
        default:
            applyMinimal(to: &config)
            configureDailyNote(config: &config, input: input)
        }

        review(config: config, paths: paths)
        guard input.confirm(prompt: "Diese Konfiguration speichern?", defaultValue: true) else {
            print("Abgebrochen. Es wurde nichts geschrieben.")
            return
        }

        try ConfigWriter.write(config: config, paths: paths, secretUpdates: secretUpdates)
        print("Setup gespeichert: \(paths.configURL.path)")
    }

    static func runConfigMenu(configPath: URL?) throws {
        let input = WizardInput()
        printHeader("Local Audio Config")
        let choice = input.choose(
            prompt: "Was moechtest du tun?",
            options: [
                "Konfiguration bearbeiten",
                "Konfiguration anzeigen",
                "Doctor ausfuehren",
                "Hard Reset auf sichere Defaults",
            ],
            defaultIndex: 0
        )
        switch choice {
        case 1:
            try show(configPath: configPath)
        case 2:
            try doctor(configPath: configPath)
        case 3:
            guard input.confirm(prompt: "Config und lokale Secrets wirklich zuruecksetzen?", defaultValue: false) else {
                print("Abgebrochen. Es wurde nichts geschrieben.")
                return
            }
            try reset(configPath: configPath, confirmed: true)
        default:
            try runSetup(configPath: configPath)
        }
    }

    static func reset(configPath: URL?, confirmed: Bool) throws {
        guard confirmed else {
            throw CliError.invalidValue("config reset requires --yes")
        }
        let paths = ConfigPaths(configPath: configPath)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.directoryURL, withIntermediateDirectories: true)
        for url in [
            paths.configURL,
            paths.dotenvURL,
            paths.supportFileURL(named: "promptConfig.json"),
            paths.supportFileURL(named: "textReplacements.json"),
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let config = freshDefaultConfig()
        try ConfigWriter.write(config: config, paths: paths, secretUpdates: [:])
        print("Config reset: \(paths.configURL.path)")
        print("Secrets reset: \(paths.dotenvURL.path)")
    }

    static func show(configPath: URL?) throws {
        let paths = ConfigPaths(configPath: configPath)
        let config = try AppConfig.load(from: paths.configURL)
        printHeader("Local Audio Config Summary")
        print("Config: \(paths.configURL.path)")
        print("Prompt config: \(config.promptConfigFile)")
        print("Text replacements: \(config.textReplacementsFile)")
        print("ASR: \(config.asr.modelVersion), language \(config.asr.language)")
        print("Audio input: \(audioInputSummary(config.audioInput))")
        print("Paste shortcut: \(config.hotkeys.paste.displayName)")
        print("Dump shortcut: \(config.hotkeys.dump.displayName)")
        print("Bluetooth shortcut: \(config.hotkeys.bluetooth.isEnabled ? config.hotkeys.bluetooth.displayName : "disabled")")
        print("Hermes Agent: \(hermesSummary(config.hermesAgent, hotkeys: config.hotkeys))")
        let bluetoothOutput = config.hotkeys.bluetooth.isEnabled
            ? config.llmOutput.bluetooth.rawValue
            : "\(config.llmOutput.bluetooth.rawValue) (inactive)"
        print("Outputs: paste=\(config.llmOutput.paste.rawValue), dump=\(config.llmOutput.dump.rawValue), bluetooth=\(bluetoothOutput)")
        print("Command LLM: \(llmSummary(config.localLLM))")
        if config.localLLM.apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("API key: not configured")
        } else {
            print("API key \(config.localLLM.apiKeyEnv): \(masked(config.localLLM.resolvedAPIKey))")
        }
        print("Daily note: \(config.dump.markdownURL.path)")
        print("Skills: \(config.skills.directoryURL.path)")
    }

    static func doctor(configPath: URL?) throws {
        let paths = ConfigPaths(configPath: configPath)
        var checks: [DoctorCheck] = []
        let fileManager = FileManager.default

        checks.append(.init(
            name: "Config file",
            passed: fileManager.fileExists(atPath: paths.configURL.path),
            detail: paths.configURL.path
        ))

        let config = try AppConfig.load(from: paths.configURL)
        checks.append(.init(
            name: "Prompt config",
            passed: fileManager.fileExists(atPath: paths.supportFileURL(named: config.promptConfigFile).path)
                || fileManager.fileExists(atPath: AppConfig.repositoryPromptConfigURL.path),
            detail: config.promptConfigFile
        ))
        checks.append(.init(
            name: "Text replacements",
            passed: fileManager.fileExists(atPath: paths.supportFileURL(named: config.textReplacementsFile).path)
                || fileManager.fileExists(atPath: AppConfig.repositoryTextReplacementsURL.path),
            detail: config.textReplacementsFile
        ))

        do {
            let inputDevice = try AudioInputDevices.resolve(config: config.audioInput)
            checks.append(.init(
                name: "Audio input",
                passed: true,
                detail: inputDevice.summary
            ))
        } catch {
            checks.append(.init(
                name: "Audio input",
                passed: false,
                detail: "\(error)"
            ))
        }

        if config.localLLM.canGenerateCommands, config.localLLM.provider != .mlx {
            let apiKeyEnv = config.localLLM.apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
            if apiKeyEnv.isEmpty {
                checks.append(.init(
                    name: "Command LLM API key",
                    passed: true,
                    detail: "not configured; requests are sent without Authorization"
                ))
            } else {
                checks.append(.init(
                    name: "Command LLM API key",
                    passed: !config.localLLM.resolvedAPIKey.isEmpty,
                    detail: "\(apiKeyEnv) in environment or \(config.localLLM.dotenvFile)"
                ))
            }
            checks.append(.init(
                name: "Chat completions URL",
                passed: config.localLLM.chatCompletionsURL != nil,
                detail: config.localLLM.chatCompletionsURL?.absoluteString ?? "missing"
            ))
        }

        if config.hermesAgent.enabled {
            let executable = hermesExecutableCheck(config.hermesAgent.executable)
            checks.append(.init(
                name: "Hermes executable",
                passed: executable.passed,
                detail: executable.detail
            ))
            if let workdir = config.hermesAgent.resolvedWorkdir {
                checks.append(.init(
                    name: "Hermes workdir",
                    passed: fileManager.fileExists(atPath: workdir),
                    detail: workdir
                ))
            }
        }

        checks.append(.init(
            name: "Skills directory",
            passed: fileManager.fileExists(atPath: config.skills.directoryURL.path),
            detail: config.skills.directoryURL.path
        ))
        checks.append(.init(
            name: "Daily note directory",
            passed: fileManager.fileExists(atPath: config.dump.markdownURL.deletingLastPathComponent().path),
            detail: config.dump.markdownURL.deletingLastPathComponent().path
        ))

        let activeBluetoothOutput =
            config.llmOutput.paste == .bluetoothKeyboard
            || config.llmOutput.dump == .bluetoothKeyboard
            || (config.hotkeys.bluetooth.isEnabled && config.llmOutput.bluetooth == .bluetoothKeyboard)
        if activeBluetoothOutput {
            let ports = detectedBluetoothPorts()
            let hasUsablePort = config.bluetoothKeyboard.resolvedPort != nil || ports.count == 1
            checks.append(.init(
                name: "Bluetooth serial port",
                passed: hasUsablePort,
                detail: config.bluetoothKeyboard.resolvedPort ?? (ports.isEmpty ? "none detected" : ports.joined(separator: ", "))
            ))
        }

        checks.append(.init(
            name: "Accessibility permission",
            passed: AXIsProcessTrusted(),
            detail: "Required for global hotkeys and paste"
        ))
        checks.append(.init(
            name: "Screen Recording permission",
            passed: CGPreflightScreenCaptureAccess(),
            detail: "Required for Hermes screenshot context"
        ))

        printHeader("Local Audio Doctor")
        for check in checks {
            print("\(check.passed ? "PASS" : "WARN") \(check.name): \(check.detail)")
        }
    }

    private static func loadWizardBaseConfig(paths: ConfigPaths) throws -> AppConfig {
        let fileManager = FileManager.default
        let sourceURL = fileManager.fileExists(atPath: paths.configURL.path)
            ? paths.configURL
            : AppConfig.repositoryRootURL.appendingPathComponent("config/config.json")
        var config = try AppConfig.load(from: sourceURL)
        config.promptConfigFile = "promptConfig.json"
        config.textReplacementsFile = "textReplacements.json"
        config.localLLM.dotenvFile = ".env"
        config.skills.directory = AppConfig.repositoryRootURL.appendingPathComponent("skills").path
        normalizeInstallLocalDefaults(&config)
        return config
    }

    private static func freshDefaultConfig() -> AppConfig {
        var config = AppConfig()
        applyQuickStart(to: &config)
        normalizeInstallLocalDefaults(&config)
        return config
    }

    private static func normalizeInstallLocalDefaults(_ config: inout AppConfig) {
        config.promptConfigFile = "promptConfig.json"
        config.textReplacementsFile = "textReplacements.json"
        config.audioInput = AudioInputConfig()
        config.localLLM.dotenvFile = ".env"
        config.localLLM.requestTimeoutSeconds = 15
        config.localLLM.maxRetries = 1
        config.localLLM.cacheSize = 4096
        config.localLLM.memorySize = 4096
        config.dump.markdownFile = defaultDailyNotePath
        config.skills.directory = AppConfig.repositoryRootURL.appendingPathComponent("skills").path
        config.hermesAgent.workdir = "~"
        config.bluetoothKeyboard.port = nil
        config.bluetoothKeyboard.chunkSize = 32
    }

    private static func applyQuickStart(to config: inout AppConfig) {
        config.localLLM.enabled = true
        config.localLLM.commandGenerationEnabled = true
        config.localLLM.provider = .openAICompatible
        config.localLLM.model = defaultOpenAIModel
        config.localLLM.endpoint = ""
        config.localLLM.baseURL = defaultOpenAIBaseURL
        config.localLLM.apiKeyEnv = defaultOpenAIAPIKeyEnv
        config.hotkeys.paste = HotkeyConfig(control: false, option: true, command: true, shift: false)
        config.hotkeys.dump = HotkeyConfig(control: true, option: true, command: false, shift: false)
        config.hotkeys.bluetooth = KeyChordConfig(keys: [], enabled: false)
        config.llmOutput.paste = .clipboard
        config.llmOutput.dump = .dump
        config.llmOutput.bluetooth = .clipboard
    }

    private static func applyMinimal(to config: inout AppConfig) {
        config.localLLM.enabled = false
        config.localLLM.commandGenerationEnabled = false
        config.dump.enabled = false
        config.continuousDump.enabled = false
        config.hotkeys.paste = HotkeyConfig(control: false, option: true, command: true, shift: false)
        config.hotkeys.dump = HotkeyConfig(control: true, option: true, command: false, shift: false)
        config.hotkeys.bluetooth = KeyChordConfig(keys: [], enabled: false)
        config.llmOutput.paste = .clipboard
        config.llmOutput.dump = .clipboard
        config.llmOutput.bluetooth = .clipboard
        config.hermesAgent.enabled = false
    }

    private static func configureCommandLLM(
        config: inout AppConfig,
        input: WizardInput,
        secretUpdates: inout [String: String]
    ) {
        let choice = input.choose(
            prompt: "Command-LLM auswaehlen",
            options: [
                "OpenAI-kompatibel",
                "Azure DeepSeek-V4-Flash",
                "Lokales MLX/Bonsai",
                "Deaktiviert",
            ],
            defaultIndex: 0
        )

        switch choice {
        case 0:
            configureOpenAICompatible(config: &config, input: input, secretUpdates: &secretUpdates)
        case 1:
            config.localLLM.enabled = true
            config.localLLM.commandGenerationEnabled = true
            config.localLLM.provider = .azureOpenAI
            config.localLLM.model = "DeepSeek-V4-Flash"
            config.localLLM.endpoint = defaultAzureEndpoint
            config.localLLM.baseURL = ""
            config.localLLM.apiKeyEnv = "AZURE_OPENAI_API_KEY"
            configureRemoteToken(config: &config, input: input, secretUpdates: &secretUpdates)
        case 2:
            config.localLLM.enabled = true
            config.localLLM.commandGenerationEnabled = true
            config.localLLM.provider = .mlx
            config.localLLM.model = input.prompt(
                "MLX model",
                defaultValue: "prism-ml/Ternary-Bonsai-8B-mlx-2bit"
            )
            config.localLLM.llmTool = input.prompt("llm-tool path", defaultValue: config.localLLM.llmTool)
            config.localLLM.mlxRun = input.prompt("mlx-run path", defaultValue: config.localLLM.mlxRun)
            config.localLLM.download = input.prompt("Model download/cache path", defaultValue: config.localLLM.download)
        case 3:
            config.localLLM.enabled = false
            config.localLLM.commandGenerationEnabled = false
        default:
            configureOpenAICompatible(config: &config, input: input, secretUpdates: &secretUpdates)
        }
    }

    private static func configureOpenAICompatible(
        config: inout AppConfig,
        input: WizardInput,
        secretUpdates: inout [String: String]
    ) {
        let preset = input.choose(
            prompt: "OpenAI-kompatibles API-Preset",
            options: [
                "OpenAI API",
                "OpenRouter",
                "Groq",
                "LM Studio lokal",
                "Custom",
            ],
            defaultIndex: 0
        )

        let defaults: (baseURL: String, model: String, apiKeyEnv: String)
        switch preset {
        case 1:
            defaults = ("https://openrouter.ai/api/v1", "openai/gpt-5.4-mini", defaultOpenAIAPIKeyEnv)
        case 2:
            defaults = ("https://api.groq.com/openai/v1", "openai/gpt-oss-20b", defaultOpenAIAPIKeyEnv)
        case 3:
            defaults = ("http://localhost:1234/v1", "local-model", "")
        case 4:
            defaults = ("https://api.example.com/v1", "", defaultOpenAIAPIKeyEnv)
        default:
            defaults = (defaultOpenAIBaseURL, defaultOpenAIModel, defaultOpenAIAPIKeyEnv)
        }

        config.localLLM.enabled = true
        config.localLLM.commandGenerationEnabled = true
        config.localLLM.provider = .openAICompatible
        config.localLLM.endpoint = ""
        config.localLLM.baseURL = input.prompt("Base URL ohne /chat/completions", defaultValue: defaults.baseURL)
        if defaults.model.isEmpty {
            config.localLLM.model = input.promptRequired("Model name/slug")
        } else {
            config.localLLM.model = input.prompt("Model name/slug", defaultValue: defaults.model)
        }
        config.localLLM.apiKeyEnv = input.prompt(
            "API key env name, leer fuer lokale Server ohne Token",
            defaultValue: defaults.apiKeyEnv
        )
        configureRemoteToken(config: &config, input: input, secretUpdates: &secretUpdates)
    }

    private static func configureRemoteToken(
        config: inout AppConfig,
        input: WizardInput,
        secretUpdates: inout [String: String]
    ) {
        let envName = config.localLLM.apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !envName.isEmpty else {
            return
        }
        let token = input.secret("API token fuer \(envName) leer lassen zum Behalten")
        if !token.isEmpty {
            secretUpdates[envName] = token
        }
    }

    private static func configureShortcuts(config: inout AppConfig, input: WizardInput) {
        config.hotkeys.paste = chooseModifierShortcut(
            label: "Paste Shortcut",
            input: input,
            defaultConfig: config.hotkeys.paste
        )
        config.hotkeys.dump = chooseModifierShortcut(
            label: "Dump Shortcut",
            input: input,
            defaultConfig: config.hotkeys.dump
        )
        if config.hotkeys.paste.displayName == config.hotkeys.dump.displayName {
            print("WARN Paste und Dump verwenden denselben Shortcut.")
        }
    }

    private static func chooseModifierShortcut(
        label: String,
        input: WizardInput,
        defaultConfig: HotkeyConfig
    ) -> HotkeyConfig {
        let choice = input.choose(
            prompt: "\(label) auswaehlen",
            options: [
                "Command + Option",
                "Control + Option",
                "Custom Capture",
            ],
            defaultIndex: defaultConfig.command ? 0 : 1
        )
        switch choice {
        case 1:
            return HotkeyConfig(control: true, option: true, command: false, shift: false)
        case 2:
            print("Halte jetzt den gewuenschten Modifier-Shortcut.")
            if case let .modifier(config)? = ShortcutCapture.capture() {
                print("Captured: \(config.displayName)")
                return config
            }
            print("Capture fehlgeschlagen; behalte \(defaultConfig.displayName).")
            return defaultConfig
        default:
            return HotkeyConfig(control: false, option: true, command: true, shift: false)
        }
    }

    private static func configureHermesAgent(config: inout AppConfig, input: WizardInput) {
        print("\nHermes Agent Trigger: \(hermesTriggerSummary(config.hotkeys))")
        let enabled = input.confirm(
            prompt: "Hermes Agent aktivieren?",
            defaultValue: config.hermesAgent.enabled
        )
        config.hermesAgent.enabled = enabled
        guard enabled else {
            return
        }

        guard input.confirm(prompt: "Hermes Agent Details anpassen?", defaultValue: false) else {
            return
        }

        config.hermesAgent.executable = input.prompt(
            "Hermes executable",
            defaultValue: config.hermesAgent.executable
        )
        config.hermesAgent.sessionName = input.prompt(
            "Hermes session name",
            defaultValue: config.hermesAgent.sessionName
        )
        config.hermesAgent.workdir = input.prompt(
            "Hermes workdir",
            defaultValue: config.hermesAgent.workdir
        )
        config.hermesAgent.foregroundTerminal = input.confirm(
            prompt: "Hermes im Terminal sichtbar oeffnen?",
            defaultValue: config.hermesAgent.foregroundTerminal
        )
        let timeout = input.prompt(
            "Hermes timeout seconds",
            defaultValue: String(Int(config.hermesAgent.timeoutSeconds))
        )
        if let value = Double(timeout), value > 0 {
            config.hermesAgent.timeoutSeconds = value
        }
    }

    private static func configureBluetooth(config: inout AppConfig, input: WizardInput) {
        let enabled = input.confirm(prompt: "Bluetooth Keyboard aktivieren?", defaultValue: config.hotkeys.bluetooth.isEnabled)
        guard enabled else {
            config.hotkeys.bluetooth = KeyChordConfig(keys: [], enabled: false)
            config.llmOutput.bluetooth = .clipboard
            config.bluetoothKeyboard.port = nil
            return
        }
        let shortcut = chooseBluetoothShortcut(input: input, defaultKey: config.hotkeys.bluetooth.keys.first)
        config.hotkeys.bluetooth = KeyChordConfig(keys: [shortcut], enabled: true)
        config.llmOutput.bluetooth = .bluetoothKeyboard

        let ports = detectedBluetoothPorts()
        if ports.count == 1 {
            print("Gefundener Port: \(ports[0])")
            if input.confirm(prompt: "Diesen Port fest speichern?", defaultValue: false) {
                config.bluetoothKeyboard.port = ports[0]
            }
        } else if ports.count > 1 {
            let index = input.choose(prompt: "Bluetooth-Port auswaehlen", options: ports, defaultIndex: 0)
            config.bluetoothKeyboard.port = ports[index]
        } else {
            config.bluetoothKeyboard.port = input.prompt("Bluetooth-Port manuell, leer fuer Auto-Detect", defaultValue: "")
        }
        if input.confirm(prompt: "Advanced: Chunk size aendern?", defaultValue: false) {
            let raw = input.prompt("Chunk size 1-256", defaultValue: String(config.bluetoothKeyboard.chunkSize))
            if let value = Int(raw), (1...256).contains(value) {
                config.bluetoothKeyboard.chunkSize = value
            }
        }
    }

    private static func chooseBluetoothShortcut(input: WizardInput, defaultKey: HotkeyKey?) -> HotkeyKey {
        let fallback = defaultKey?.keyCode == nil ? HotkeyKey.defaultBluetoothKey : (defaultKey ?? .defaultBluetoothKey)
        let raw = input.prompt(
            "Bluetooth Shortcut-Key, z.B. f18, right_shift, right_option; Enter fuer Default",
            defaultValue: fallback.rawValue
        )
        guard let key = HotkeyKey.parse(raw) else {
            print("WARN Unbekannter Bluetooth-Key '\(raw)'; verwende \(fallback.rawValue).")
            return fallback
        }
        print("Bluetooth Shortcut: \(key.displayName)")
        return key
    }

    private static func configureOutputs(config: inout AppConfig, input: WizardInput) {
        config.llmOutput.paste = chooseOutput(label: "Paste Output", input: input, defaultMethod: config.llmOutput.paste)
        config.llmOutput.dump = chooseOutput(label: "Dump Output", input: input, defaultMethod: config.llmOutput.dump)
        if !config.hotkeys.bluetooth.isEnabled {
            config.llmOutput.bluetooth = .clipboard
        } else {
            config.llmOutput.bluetooth = chooseOutput(label: "Bluetooth Output", input: input, defaultMethod: config.llmOutput.bluetooth)
        }
    }

    private static func chooseOutput(
        label: String,
        input: WizardInput,
        defaultMethod: LLMOutputMethod
    ) -> LLMOutputMethod {
        let methods: [LLMOutputMethod] = [.clipboard, .dump, .bluetoothKeyboard]
        let defaultIndex = methods.firstIndex(of: defaultMethod) ?? 0
        let index = input.choose(prompt: label, options: methods.map(\.rawValue), defaultIndex: defaultIndex)
        return methods[index]
    }

    private static func configureDailyNote(config: inout AppConfig, input: WizardInput) {
        let current = config.dump.markdownFile
        let suggested = current.isEmpty || isLegacyBundledDailyNotePath(current) ? defaultDailyNotePath : current
        config.dump.markdownFile = input.prompt("Daily Note Pfad", defaultValue: suggested)
    }

    private static func isLegacyBundledDailyNotePath(_ path: String) -> Bool {
        path.contains("OneDrive-Personal/Obsidian/") && path.contains("Daily Notes/")
    }

    private static func review(config: AppConfig, paths: ConfigPaths) {
        printHeader("Review")
        print("Config: \(paths.configURL.path)")
        print("Command LLM: \(llmSummary(config.localLLM))")
        print("Paste: \(config.hotkeys.paste.displayName) -> \(config.llmOutput.paste.rawValue)")
        print("Dump: \(config.hotkeys.dump.displayName) -> \(config.llmOutput.dump.rawValue)")
        print("Bluetooth: \(config.hotkeys.bluetooth.isEnabled ? config.hotkeys.bluetooth.displayName : "disabled") -> \(config.llmOutput.bluetooth.rawValue)")
        print("Hermes Agent: \(hermesSummary(config.hermesAgent, hotkeys: config.hotkeys))")
        print("Daily note: \(config.dump.markdownFile)")
        print("Skills: \(config.skills.directory)")
        print("Secret file: \(paths.dotenvURL.path)")
    }

    private static func printHeader(_ text: String) {
        print("\n=== \(text) ===")
    }

    private static let defaultDailyNotePath = "~/Documents/Obsidian/Daily Notes/YYYY-MM-DD.md"

    private static func llmSummary(_ config: LocalLLMConfig) -> String {
        guard config.canGenerateCommands else {
            return "disabled"
        }
        switch config.provider {
        case .azureOpenAI:
            return "Azure OpenAI \(config.model) @ \(config.endpoint)"
        case .openAICompatible:
            return "OpenAI-compatible \(config.model) @ \(config.chatCompletionsURL?.absoluteString ?? config.baseURL)"
        case .mlx:
            return "MLX \(config.model)"
        }
    }

    private static func hermesSummary(_ config: HermesAgentConfig, hotkeys: HotkeysConfig) -> String {
        guard config.enabled else {
            return "disabled"
        }
        return "enabled, trigger=\(hermesTriggerSummary(hotkeys)), executable=\(config.executable), session=\(config.sessionName), workdir=\(config.workdir)"
    }

    private static func hermesTriggerSummary(_ hotkeys: HotkeysConfig) -> String {
        "\(hotkeys.paste.displayName) halten, Command loslassen, Option weiter halten"
    }

    private static func masked(_ value: String) -> String {
        guard !value.isEmpty else { return "missing" }
        guard value.count > 8 else { return "set" }
        return "\(value.prefix(4))...\(value.suffix(4))"
    }

    private static func audioInputSummary(_ config: AudioInputConfig) -> String {
        (try? AudioInputDevices.resolve(config: config).summary) ?? "missing"
    }

    private static func detectedBluetoothPorts() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .map { "/dev/\($0)" }
            .sorted() ?? []
    }

    private static func hermesExecutableCheck(_ executable: String) -> (passed: Bool, detail: String) {
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "missing")
        }

        let fileManager = FileManager.default
        if trimmed.contains("/") {
            let expanded = trimmed.expandingTilde
            return (fileManager.isExecutableFile(atPath: expanded), expanded)
        }

        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(trimmed)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return (true, candidate)
            }
        }
        return (false, "\(trimmed) not found in PATH")
    }
}

struct ConfigPaths {
    let configURL: URL

    init(configPath: URL?) {
        configURL = configPath ?? AppConfig.defaultURL
    }

    var directoryURL: URL {
        configURL.deletingLastPathComponent()
    }

    var dotenvURL: URL {
        directoryURL.appendingPathComponent(".env")
    }

    func supportFileURL(named name: String) -> URL {
        directoryURL.appendingPathComponent(name)
    }
}

enum ConfigWriter {
    static func write(config: AppConfig, paths: ConfigPaths, secretUpdates: [String: String]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.directoryURL, withIntermediateDirectories: true)
        try copySupportFiles(paths: paths)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try atomicWrite(data: data, to: paths.configURL)

        try DotEnvWriter.ensure(url: paths.dotenvURL)
        for (key, value) in secretUpdates where !value.isEmpty {
            try DotEnvWriter.update(url: paths.dotenvURL, key: key, value: value)
        }
    }

    private static func copySupportFiles(paths: ConfigPaths) throws {
        let fileManager = FileManager.default
        let files = [
            ("promptConfig.json", AppConfig.repositoryPromptConfigURL),
            ("textReplacements.json", AppConfig.repositoryTextReplacementsURL),
        ]
        for (name, source) in files {
            let destination = paths.supportFileURL(named: name)
            guard !fileManager.fileExists(atPath: destination.path) else {
                continue
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}

enum DotEnvWriter {
    static func ensure(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    static func update(url: URL, key: String, value: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = (try? String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)) ?? []
        let replacement = "\(key)=\(escaped(value))"
        var didReplace = false
        lines = lines.map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) == key else {
                return line
            }
            didReplace = true
            return replacement
        }
        if !didReplace {
            if !lines.isEmpty, lines.last == "" {
                lines.removeLast()
            }
            lines.append(replacement)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    private static func escaped(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#'\""))) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct DoctorCheck {
    let name: String
    let passed: Bool
    let detail: String
}

final class WizardInput {
    func choose(prompt: String, options: [String], defaultIndex: Int) -> Int {
        while true {
            print("\n\(prompt)")
            for (index, option) in options.enumerated() {
                let marker = index == defaultIndex ? " (default)" : ""
                print("  \(index + 1)) \(option)\(marker)")
            }
            print("Auswahl [\(defaultIndex + 1)] (b zurueck nicht verfuegbar, q abbrechen): ", terminator: "")
            let value = readTrimmedLine()
            if value.isEmpty {
                return defaultIndex
            }
            if value.lowercased() == "q" {
                print("Abgebrochen.")
                exit(0)
            }
            if let number = Int(value), (1...options.count).contains(number) {
                return number - 1
            }
            print("Ungueltige Auswahl.")
        }
    }

    func confirm(prompt: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? "Y/n" : "y/N"
        print("\(prompt) [\(suffix)]: ", terminator: "")
        let value = readTrimmedLine().lowercased()
        if value.isEmpty {
            return defaultValue
        }
        return ["y", "yes", "j", "ja"].contains(value)
    }

    func prompt(_ prompt: String, defaultValue: String) -> String {
        print("\(prompt) [\(defaultValue)]: ", terminator: "")
        let value = readTrimmedLine()
        return value.isEmpty ? defaultValue : value
    }

    func promptRequired(_ prompt: String) -> String {
        while true {
            print("\(prompt): ", terminator: "")
            let value = readTrimmedLine()
            if !value.isEmpty {
                return value
            }
            print("Dieses Feld ist erforderlich.")
        }
    }

    func secret(_ prompt: String) -> String {
        print("\(prompt): ", terminator: "")
        fflush(stdout)
        if isatty(STDIN_FILENO) == 1 {
            return readHiddenLine()
        }
        return readTrimmedLine()
    }

    private func readTrimmedLine() -> String {
        Swift.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func readHiddenLine() -> String {
        var old = termios()
        guard tcgetattr(STDIN_FILENO, &old) == 0 else {
            return readTrimmedLine()
        }
        var new = old
        new.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &new)
        let value = Swift.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tcsetattr(STDIN_FILENO, TCSANOW, &old)
        print("")
        return value
    }
}

enum CapturedShortcut {
    case modifier(HotkeyConfig)
}

enum ShortcutCapture {
    static func capture() -> CapturedShortcut? {
        let pollInterval: useconds_t = 50_000
        let stableDuration: TimeInterval = 0.35
        let timeout: TimeInterval = 10
        let startedAt = Date()
        var lastObserved: HotkeyConfig?
        var stableSince = Date()

        while Date().timeIntervalSince(startedAt) < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let captured = HotkeyConfig(
                control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate),
                command: flags.contains(.maskCommand),
                shift: flags.contains(.maskShift)
            )
            guard captured.control || captured.option || captured.command || captured.shift else {
                usleep(pollInterval)
                continue
            }
            if let lastObserved, lastObserved.displayName == captured.displayName {
                if Date().timeIntervalSince(stableSince) >= stableDuration {
                    return .modifier(captured)
                }
            } else {
                lastObserved = captured
                stableSince = Date()
            }
            usleep(pollInterval)
        }
        return nil
    }
}
