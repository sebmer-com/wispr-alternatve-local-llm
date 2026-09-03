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
    static func runSetup(configPath: URL?) throws {
        let paths = ConfigPaths(configPath: configPath)
        let input = WizardInput()
        var config = try loadWizardBaseConfig(paths: paths)

        printHeader("Local Audio Setup")
        var secretUpdates: [String: String] = [:]
        printModeDescription(
            "Local transcription stays on your Mac. Command mode sends your transcript, instruction, and (when permitted) screenshots to the selected command provider."
        )
        configureASR(config: &config, input: input)
        configurePasteShortcut(config: &config, input: input)
        configureCommandProvider(config: &config, input: input)
        configureProviderKey(config: config, input: input, secretUpdates: &secretUpdates)
        configureControlOptionMode(config: &config, input: input)
        explainScreenRecording(input: input)
        review(config: config, paths: paths, includeOptionalFeatures: false)
        guard input.confirm(prompt: "Save this configuration?", defaultValue: true) else {
            print("Canceled. No changes were written.")
            return
        }

        try ConfigWriter.write(config: config, paths: paths, secretUpdates: secretUpdates)
        print("Setup saved: \(paths.configURL.path)")
    }

    private static func runOptionalFeaturesEditor(configPath: URL?) throws {
        let paths = ConfigPaths(configPath: configPath)
        let input = WizardInput()
        var config = try loadWizardBaseConfig(paths: paths)

        printHeader("Optional Features")
        printModeDescription(
            "Configure the Control + Option mode, Hermes details, continuous Markdown dump, Bluetooth output, and paths. Command provider selection remains in core setup."
        )
        configureDumpShortcut(config: &config, input: input)
        configureControlOptionMode(config: &config, input: input)
        config.continuousDump.enabled = input.confirm(
            prompt: "Enable stop-triggered continuous dump?",
            defaultValue: config.continuousDump.enabled
        )
        if config.continuousDump.enabled {
            config.dump.enabled = true
        }
        configureHermesAgent(config: &config, input: input)
        configureBluetooth(config: &config, input: input)
        configureOutputs(config: &config, input: input)
        if config.continuousDump.enabled, config.controlOptionMode != .dump {
            configureDailyNote(config: &config, input: input)
        }
        config.recordings.save = input.confirm(
            prompt: "Keep audio recordings?",
            defaultValue: config.recordings.save
        )
        config.recordings.outputDir = input.prompt(
            "Recording output directory",
            defaultValue: config.recordings.outputDir
        )

        review(config: config, paths: paths, includeOptionalFeatures: true)
        guard input.confirm(prompt: "Save this configuration?", defaultValue: true) else {
            print("Canceled. No changes were written.")
            return
        }
        try ConfigWriter.write(config: config, paths: paths, secretUpdates: [:])
        print("Configuration saved: \(paths.configURL.path)")
    }

    static func runConfigMenu(configPath: URL?) throws {
        let input = WizardInput()
        printHeader("Local Audio Config")
        let choice = input.choose(
            prompt: "What would you like to do?",
            options: [
                "Edit core setup",
                "Edit optional features",
                "Show configuration",
                "Run doctor",
                "Hard reset to safe defaults",
            ],
            defaultIndex: 0
        )
        switch choice {
        case 1:
            try runOptionalFeaturesEditor(configPath: configPath)
        case 2:
            try show(configPath: configPath)
        case 3:
            try doctor(configPath: configPath)
        case 4:
            guard input.confirm(prompt: "Reset config and local secrets?", defaultValue: false) else {
                print("Canceled. No changes were written.")
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
        print("ASR: \(config.asr.modelVersion), language \(asrLanguageSummary(config.asr.language))")
        print("Audio input: \(audioInputSummary(config.audioInput))")
        print("Paste shortcut: \(config.hotkeys.paste.displayName)")
        print("Control + Option shortcut: \(config.hotkeys.dump.displayName)")
        print("Control + Option mode: \(config.controlOptionMode.displayName)")
        print("Bluetooth shortcut: \(config.hotkeys.bluetooth.isEnabled ? config.hotkeys.bluetooth.displayName : "disabled")")
        print("Hermes Agent: \(hermesSummary(config))")
        let bluetoothOutput = config.hotkeys.bluetooth.isEnabled
            ? config.llmOutput.bluetooth.rawValue
            : "\(config.llmOutput.bluetooth.rawValue) (inactive)"
        print("Outputs: paste=\(config.llmOutput.paste.rawValue), dump=\(config.llmOutput.dump.rawValue), bluetooth=\(bluetoothOutput)")
        print("Command LLM: \(providerSummary(config.commandProvider))")
        print("API key \(config.commandProvider.apiKeyEnvironmentName): \(masked(config.commandProvider.resolveAPIKey(configURL: paths.configURL)))")
        print("Screen Recording permission: \(CGPreflightScreenCaptureAccess() ? "granted" : "missing (text-only fallback remains available)")")
        print("Daily note: \(config.dump.markdownURL.path)")
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
        checks.append(.init(
            name: "ASR language",
            passed: AsrLanguageResolver.isValidPreference(config.asr.language),
            detail: asrLanguageSummary(config.asr.language)
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

        checks.append(.init(
            name: "Command provider",
            passed: true,
            detail: providerSummary(config.commandProvider)
        ))
        checks.append(.init(
            name: "Control + Option mode",
            passed: true,
            detail: config.controlOptionMode.displayName
        ))
        checks.append(.init(
            name: "\(config.commandProvider.displayName) API key",
            passed: !config.commandProvider.resolveAPIKey(configURL: paths.configURL).isEmpty,
            detail: "\(config.commandProvider.apiKeyEnvironmentName) in environment or \(paths.dotenvURL.path)"
        ))

        if config.controlOptionMode == .hermes {
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

        if config.controlOptionMode == .dump || config.continuousDump.enabled {
            checks.append(.init(
                name: "Daily note directory",
                passed: fileManager.fileExists(atPath: config.dump.markdownURL.deletingLastPathComponent().path),
                detail: config.dump.markdownURL.deletingLastPathComponent().path
            ))
        }

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
            detail: "Required for command screenshot context"
        ))

        printHeader("Local Audio Doctor")
        for check in checks {
            print("\(check.passed ? "PASS" : "WARN") \(check.name): \(check.detail)")
        }
    }

    private static func loadWizardBaseConfig(paths: ConfigPaths) throws -> AppConfig {
        let fileManager = FileManager.default
        let configExists = fileManager.fileExists(atPath: paths.configURL.path)
        let sourceURL = configExists
            ? paths.configURL
            : AppConfig.repositoryRootURL.appendingPathComponent("config/config.json")
        var config = try AppConfig.load(from: sourceURL)
        if configExists {
            config.asr.language = AsrLanguageResolver.normalizePreference(config.asr.language)
        } else {
            normalizeInstallLocalDefaults(&config)
        }
        return config
    }

    private static func freshDefaultConfig() -> AppConfig {
        var config = AppConfig()
        config.hotkeys.dump = HotkeyConfig(control: true, option: true, command: false, shift: false)
        config.hotkeys.bluetooth = KeyChordConfig(keys: [], enabled: false)
        config.controlOptionMode = .dump
        config.llmOutput.dump = .dump
        config.llmOutput.bluetooth = .clipboard
        config.dump.enabled = true
        config.continuousDump.enabled = false
        normalizeInstallLocalDefaults(&config)
        return config
    }

    private static func normalizeInstallLocalDefaults(_ config: inout AppConfig) {
        config.promptConfigFile = "promptConfig.json"
        config.textReplacementsFile = "textReplacements.json"
        config.audioInput = AudioInputConfig()
        config.asr.language = AsrLanguageResolver.normalizePreference(config.asr.language)
        config.dump.markdownFile = defaultDailyNotePath
        config.hermesAgent.workdir = "~"
        config.bluetoothKeyboard.port = nil
        config.bluetoothKeyboard.chunkSize = 32
    }

    private static func configureASR(config: inout AppConfig, input: WizardInput) {
        let systemCode = AsrLanguageResolver.systemSupportedLanguageCode() ?? AsrLanguageResolver.autoPreference
        let current = AsrLanguageResolver.normalizePreference(config.asr.language)
        let options = [
            "System Language (\(systemCode))",
            "Auto detect",
            "German (de)",
            "English (en)",
            "Spanish (es)",
            "French (fr)",
            "Custom code",
        ]
        let defaultIndex: Int
        switch current {
        case AsrLanguageResolver.autoPreference:
            defaultIndex = 1
        case "de":
            defaultIndex = 2
        case "en":
            defaultIndex = 3
        case "es":
            defaultIndex = 4
        case "fr":
            defaultIndex = 5
        case AsrLanguageResolver.systemPreference:
            defaultIndex = 0
        default:
            defaultIndex = 6
        }

        let choice = input.choose(prompt: "Transcription language", options: options, defaultIndex: defaultIndex)
        switch choice {
        case 1:
            config.asr.language = AsrLanguageResolver.autoPreference
        case 2:
            config.asr.language = "de"
        case 3:
            config.asr.language = "en"
        case 4:
            config.asr.language = "es"
        case 5:
            config.asr.language = "fr"
        case 6:
            let raw = input.prompt(
                "Language code",
                defaultValue: AsrLanguageResolver.isValidPreference(current) ? current : AsrLanguageResolver.systemPreference
            )
            let normalized = AsrLanguageResolver.normalizePreference(raw)
            if AsrLanguageResolver.isValidPreference(normalized) {
                config.asr.language = normalized
            } else {
                print("WARN Unsupported ASR language '\(raw)'; using system.")
                config.asr.language = AsrLanguageResolver.systemPreference
            }
        default:
            config.asr.language = AsrLanguageResolver.systemPreference
        }
    }

    private static func configureCommandProvider(config: inout AppConfig, input: WizardInput) {
        let providers: [CommandProvider] = [.openAI, .cerebras, .gemini]
        let defaultIndex = providers.firstIndex(of: config.commandProvider) ?? 0
        let choice = input.choose(
            prompt: "Choose command provider",
            options: [
                "OpenAI — gpt-5.6-luna, low reasoning, low-detail screenshots",
                "Cerebras — gemma-4-31b",
                "Gemini — gemini-3.5-flash",
            ],
            defaultIndex: defaultIndex
        )
        config.commandProvider = providers[choice]
    }

    private static func configureProviderKey(
        config: AppConfig,
        input: WizardInput,
        secretUpdates: inout [String: String]
    ) {
        let provider = config.commandProvider
        let token = input.secret(
            "\(provider.displayName) API key for \(provider.apiKeyEnvironmentName) (hidden; leave blank to keep current)"
        )
        if !token.isEmpty {
            secretUpdates[provider.apiKeyEnvironmentName] = token
        }
    }

    private static func configureControlOptionMode(config: inout AppConfig, input: WizardInput) {
        let modes: [ControlOptionMode] = [.dump, .hermes]
        let defaultIndex = modes.firstIndex(of: config.controlOptionMode) ?? 0
        let choice = input.choose(
            prompt: "Choose Control + Option mode",
            options: [
                "Markdown Dump — transcript and optional P screenshots",
                "Hermes Agent — one spoken instruction and optional P screenshots",
            ],
            defaultIndex: defaultIndex
        )
        config.controlOptionMode = modes[choice]
        if config.controlOptionMode == .dump {
            config.dump.enabled = true
            config.llmOutput.dump = .dump
            configureDailyNote(config: &config, input: input)
        }
    }

    private static func explainScreenRecording(input: WizardInput) {
        print("")
        print("Command, Markdown Dump, and Hermes modes can include up to five full-desktop screenshots captured explicitly with P.")
        print("macOS will ask for Screen Recording permission when screenshot context is used. Without permission, every mode continues with text only.")
        if !CGPreflightScreenCaptureAccess(), isatty(STDIN_FILENO) == 1,
           input.confirm(prompt: "Request Screen Recording permission now?", defaultValue: true) {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private static func configurePasteShortcut(config: inout AppConfig, input: WizardInput) {
        config.hotkeys.paste = chooseModifierShortcut(
            label: "Paste Shortcut",
            input: input,
            defaultConfig: config.hotkeys.paste
        )
    }

    private static func configureDumpShortcut(config: inout AppConfig, input: WizardInput) {
        config.hotkeys.dump = chooseModifierShortcut(
            label: "Dump Shortcut",
            input: input,
            defaultConfig: config.hotkeys.dump
        )
        if config.hotkeys.paste.displayName == config.hotkeys.dump.displayName {
            print("WARN Paste and Dump use the same shortcut.")
        }
    }

    private static func chooseModifierShortcut(
        label: String,
        input: WizardInput,
        defaultConfig: HotkeyConfig
    ) -> HotkeyConfig {
        let alternate = defaultConfig.command
            ? HotkeyConfig(control: true, option: true, command: false, shift: false)
            : HotkeyConfig(control: false, option: true, command: true, shift: false)
        let choice = input.choose(
            prompt: "Configure \(label)",
            options: [
                "Keep default: \(defaultConfig.displayName)",
                "Use preset: \(alternate.displayName)",
                "Capture custom shortcut",
            ],
            defaultIndex: 0
        )
        switch choice {
        case 1:
            return alternate
        case 2:
            print("Hold the shortcut now. Release when captured.")
            if case let .modifier(config)? = ShortcutCapture.capture() {
                print("Captured: \(config.displayName)")
                return config
            }
            print("Capture timed out. Keeping \(defaultConfig.displayName).")
            return defaultConfig
        default:
            return defaultConfig
        }
    }

    private static func configureHermesAgent(config: inout AppConfig, input: WizardInput) {
        guard config.controlOptionMode == .hermes else {
            return
        }
        print("\nHermes Agent Trigger: \(hermesTriggerSummary(config.hotkeys))")

        guard input.confirm(prompt: "Customize Hermes Agent details?", defaultValue: false) else {
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
            prompt: "Open Hermes in a visible Terminal window?",
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
        let enabled = input.confirm(prompt: "Enable Bluetooth keyboard output?", defaultValue: config.hotkeys.bluetooth.isEnabled)
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
            print("Detected port: \(ports[0])")
            if input.confirm(prompt: "Save this port explicitly?", defaultValue: false) {
                config.bluetoothKeyboard.port = ports[0]
            }
        } else if ports.count > 1 {
            let index = input.choose(prompt: "Choose Bluetooth port", options: ports, defaultIndex: 0)
            config.bluetoothKeyboard.port = ports[index]
        } else {
            config.bluetoothKeyboard.port = input.prompt("Bluetooth port, leave empty for auto-detect", defaultValue: "")
        }
        if input.confirm(prompt: "Advanced: change chunk size?", defaultValue: false) {
            let raw = input.prompt("Chunk size 1-256", defaultValue: String(config.bluetoothKeyboard.chunkSize))
            if let value = Int(raw), (1...256).contains(value) {
                config.bluetoothKeyboard.chunkSize = value
            }
        }
    }

    private static func chooseBluetoothShortcut(input: WizardInput, defaultKey: HotkeyKey?) -> HotkeyKey {
        let fallback = defaultKey?.keyCode == nil ? HotkeyKey.defaultBluetoothKey : (defaultKey ?? .defaultBluetoothKey)
        let raw = input.prompt(
            "Bluetooth shortcut key, for example f18, right_shift, right_option",
            defaultValue: fallback.rawValue
        )
        guard let key = HotkeyKey.parse(raw) else {
            print("WARN Unknown Bluetooth key '\(raw)'; using \(fallback.rawValue).")
            return fallback
        }
        print("Bluetooth Shortcut: \(key.displayName)")
        return key
    }

    private static func configureOutputs(config: inout AppConfig, input: WizardInput) {
        config.llmOutput.paste = chooseOutput(label: "Paste Output", input: input, defaultMethod: config.llmOutput.paste)
        if config.controlOptionMode == .dump {
            config.llmOutput.dump = .dump
        } else {
            config.llmOutput.dump = chooseOutput(label: "Dump Output", input: input, defaultMethod: config.llmOutput.dump)
        }
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
        config.dump.markdownFile = input.prompt("Daily note path", defaultValue: suggested)
    }

    private static func isLegacyBundledDailyNotePath(_ path: String) -> Bool {
        path.contains("OneDrive-Personal/Obsidian/") && path.contains("Daily Notes/")
    }

    private static func review(config: AppConfig, paths: ConfigPaths, includeOptionalFeatures: Bool) {
        printHeader("Review")
        print("Config: \(paths.configURL.path)")
        print("ASR language: \(asrLanguageSummary(config.asr.language))")
        print("Command LLM: \(providerSummary(config.commandProvider))")
        print("Paste shortcut: \(config.hotkeys.paste.displayName) -> \(config.llmOutput.paste.rawValue)")
        print("Control + Option: \(config.hotkeys.dump.displayName) -> \(config.controlOptionMode.displayName)")
        if includeOptionalFeatures {
            print("Bluetooth: \(config.hotkeys.bluetooth.isEnabled ? config.hotkeys.bluetooth.displayName : "disabled") -> \(config.llmOutput.bluetooth.rawValue)")
            print("Hermes Agent: \(hermesSummary(config))")
            print("Daily note: \(config.dump.markdownFile)")
        }
        print("Secret file: \(paths.dotenvURL.path)")
    }

    private static func printModeDescription(_ text: String) {
        print("")
        print(text)
    }

    private static func printHeader(_ text: String) {
        print("\n=== \(text) ===")
    }

    private static let defaultDailyNotePath = "~/Documents/Obsidian/Daily Notes/YYYY-MM-DD.md"

    private static func asrLanguageSummary(_ language: String) -> String {
        AsrLanguageResolver.resolve(language).displayValue
    }

    private static func providerSummary(_ provider: CommandProvider) -> String {
        switch provider {
        case .openAI:
            return "OpenAI Responses \(OpenAISecrets.model), reasoning=\(OpenAISecrets.reasoningEffort), screenshots=up to 5, detail=\(OpenAISecrets.imageDetail)"
        case .cerebras:
            return "Cerebras Chat Completions \(CerebrasSecrets.model), screenshots=up to 5"
        case .gemini:
            return "Gemini generateContent \(GeminiSecrets.model), screenshots=up to 5"
        }
    }

    private static func hermesSummary(_ config: AppConfig) -> String {
        guard config.controlOptionMode == .hermes else {
            return "inactive"
        }
        let agent = config.hermesAgent
        return "active, trigger=\(hermesTriggerSummary(config.hotkeys)), executable=\(agent.executable), session=\(agent.sessionName), workdir=\(agent.workdir)"
    }

    private static func hermesTriggerSummary(_ hotkeys: HotkeysConfig) -> String {
        "hold \(hotkeys.dump.displayName), speak once, release either modifier"
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
    func choose(prompt: String, options: [String], defaultIndex: Int, marksDefaultOption: Bool = true) -> Int {
        while true {
            print("\n\(prompt)")
            for (index, option) in options.enumerated() {
                let marker = marksDefaultOption && index == defaultIndex ? " (default)" : ""
                print("  \(index + 1)) \(option)\(marker)")
            }
            print("Selection [\(defaultIndex + 1)] (q to quit): ", terminator: "")
            let value = readTrimmedLine()
            if value.isEmpty {
                return defaultIndex
            }
            if value.lowercased() == "q" {
                print("Canceled. No changes were written.")
                exit(0)
            }
            if let number = Int(value), (1...options.count).contains(number) {
                return number - 1
            }
            print("Invalid selection.")
        }
    }

    func confirm(prompt: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? "Y/n" : "y/N"
        print("\(prompt) [\(suffix)]: ", terminator: "")
        let value = readTrimmedLine().lowercased()
        if value.isEmpty {
            return defaultValue
        }
        return ["y", "yes"].contains(value)
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
            print("This field is required.")
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
