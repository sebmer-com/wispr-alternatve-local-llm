import FluidAudio
import Foundation

struct Options {
    var configPath: URL?
    var config = AppConfig()
    var command = RuntimeCommand.run
    var testCommandInformation: String?
    var testCommand: String?
    var testBluetoothKeyboardText: String?
    var configResetConfirmed = false

    var activeConfigURL: URL {
        configPath ?? AppConfig.defaultURL
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        let commandParse = parseRuntimeCommand(arguments)
        options.command = commandParse.command
        options.configPath = try parseConfigPath(arguments)
        options.config = try AppConfig.load(from: options.configPath)

        if options.command == .configReset {
            options.configResetConfirmed = arguments.contains("--yes")
            return options
        }
        if options.command != .run {
            return options
        }
        if options.configPath == nil,
           !FileManager.default.fileExists(atPath: AppConfig.defaultURL.path),
           !arguments.contains("--help"),
           !arguments.contains("-h") {
            options.command = .setup
            return options
        }

        var index = 1

        while index < arguments.count {
            if commandParse.skipIndices.contains(index) {
                index += 1
                continue
            }
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                printHelp()
                exit(0)
            case "--config":
                _ = try value(after: argument, in: arguments, at: &index)
            case "--model-version":
                options.config.asr.modelVersion = try value(after: argument, in: arguments, at: &index)
            case "--language":
                options.config.asr.language = try value(after: argument, in: arguments, at: &index)
            case "--output-dir":
                options.config.recordings.outputDir = try value(after: argument, in: arguments, at: &index)
            case "--no-paste":
                options.config.paste.enabled = false
            case "--paste":
                options.config.paste.enabled = true
            case "--no-restore-clipboard":
                options.config.paste.restoreClipboard = false
            case "--save-recordings":
                options.config.recordings.save = true
            case "--paste-delay":
                options.config.paste.pasteDelay = try numericValue(after: argument, in: arguments, at: &index)
            case "--restore-clipboard-delay":
                options.config.paste.restoreClipboardDelay = try numericValue(
                    after: argument,
                    in: arguments,
                    at: &index
                )
            case "--test-command-information":
                options.testCommandInformation = try value(after: argument, in: arguments, at: &index)
            case "--test-command":
                options.testCommand = try value(after: argument, in: arguments, at: &index)
            case "--test-bluetooth-keyboard":
                options.testBluetoothKeyboardText = try value(after: argument, in: arguments, at: &index)
            default:
                throw CliError.invalidArgument(argument)
            }

            index += 1
        }

        try validate(options)
        return options
    }

    private static func validate(_ options: Options) throws {
        if !["v2", "v3"].contains(options.config.asr.modelVersion) {
            throw CliError.invalidValue("--model-version must be v2 or v3")
        }
        if options.config.asr.language != "auto", Language(rawValue: options.config.asr.language) == nil {
            throw CliError.invalidValue("--language must be auto or a supported code like de, en, es, fr")
        }
        if options.config.paste.pasteDelay < 0 {
            throw CliError.invalidValue("--paste-delay must not be negative")
        }
        if options.config.paste.restoreClipboardDelay < 0 {
            throw CliError.invalidValue("--restore-clipboard-delay must not be negative")
        }
        if !(1...256).contains(options.config.bluetoothKeyboard.chunkSize) {
            throw CliError.invalidValue("bluetooth_keyboard.chunk_size must be between 1 and 256")
        }
        if let invalidBluetoothKey = options.config.hotkeys.bluetooth.keys.first(where: { $0.keyCode == nil }) {
            throw CliError.invalidValue(
                "hotkeys.bluetooth.keys contains unsupported key '\(invalidBluetoothKey.rawValue)'"
            )
        }
        if options.config.localLLM.maxTokens <= 0 {
            throw CliError.invalidValue("local_llm.max_tokens must be greater than zero")
        }
        if options.config.localLLM.cacheSize <= 0 {
            throw CliError.invalidValue("local_llm.cache_size must be greater than zero")
        }
        if options.config.localLLM.memorySize <= 0 {
            throw CliError.invalidValue("local_llm.memory_size must be greater than zero")
        }
        if options.config.localLLM.timeoutSeconds <= 0 {
            throw CliError.invalidValue("local_llm.timeout_seconds must be greater than zero")
        }
        if options.config.localLLM.requestTimeoutSeconds <= 0 {
            throw CliError.invalidValue("local_llm.request_timeout_seconds must be greater than zero")
        }
        if options.config.localLLM.maxRetries < 0 {
            throw CliError.invalidValue("local_llm.max_retries must not be negative")
        }
        if options.config.localLLM.provider == .azureOpenAI || options.config.localLLM.provider == .openAICompatible {
            if options.config.localLLM.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CliError.invalidValue("local_llm.model must be set for remote command generation")
            }
            if options.config.localLLM.chatCompletionsURL == nil {
                throw CliError.invalidValue(
                    "local_llm.endpoint or local_llm.base_url must be a valid chat completions URL"
                )
            }
            let apiKeyEnv = options.config.localLLM.apiKeyEnv.trimmingCharacters(in: .whitespacesAndNewlines)
            if options.config.localLLM.canGenerateCommands,
               (options.testCommandInformation != nil || options.testCommand != nil),
               !apiKeyEnv.isEmpty,
               options.config.localLLM.resolvedAPIKey.isEmpty {
                throw CliError.invalidValue(
                    "\(apiKeyEnv) must be set in the environment or local_llm.dotenv_file"
                )
            }
        }
        if (options.testCommandInformation == nil) != (options.testCommand == nil) {
            throw CliError.invalidValue("--test-command-information and --test-command must be used together")
        }
    }

    private static func parseRuntimeCommand(_ arguments: [String]) -> (command: RuntimeCommand, skipIndices: Set<Int>) {
        guard arguments.count > 1 else {
            return (.run, [])
        }
        switch arguments[1] {
        case "setup":
            return (.setup, [1])
        case "config":
            if arguments.count > 2 {
                switch arguments[2] {
                case "show":
                    return (.configShow, [1, 2])
                case "doctor":
                    return (.configDoctor, [1, 2])
                case "reset":
                    return (.configReset, [1, 2])
                default:
                    return (.configMenu, [1])
                }
            }
            return (.configMenu, [1])
        default:
            return (.run, [])
        }
    }

    private static func parseConfigPath(_ arguments: [String]) throws -> URL? {
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--config" {
                let rawPath = try value(after: "--config", in: arguments, at: &index)
                return URL(fileURLWithPath: rawPath.expandingTilde)
            }
            index += 1
        }
        return nil
    }

    private static func value(
        after argument: String,
        in arguments: [String],
        at index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CliError.invalidValue("\(argument) requires a value")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func numericValue(
        after argument: String,
        in arguments: [String],
        at index: inout Int
    ) throws -> TimeInterval {
        let rawValue = try value(after: argument, in: arguments, at: &index)
        guard let value = TimeInterval(rawValue) else {
            throw CliError.invalidValue("\(argument) requires a numeric value")
        }
        return value
    }

    static func printHelp() {
        print(
            """
            Usage: fluid-push-to-talk [options]
                   fluid-push-to-talk setup [--config PATH]
                   fluid-push-to-talk config [show|doctor|reset] [--config PATH]

            Hold Command + Option to record and paste. System audio is muted while recording and restored after capture.
            Release Option first while holding Command to record a local command, then paste the LLM result when available.
            Release Command first while holding Option to record a Hermes Agent instruction; a real Hermes/Poseidon session is foregrounded, the full prompt is visibly pasted and submitted there, and the answer exported from that same session is delivered back to the original app or clipboard.
            Hold Control + Option to record and dump raw text.
            Release Control first while holding Option to record a command, then dump the LLM result when available.
            After launch, type go and stop in the app Terminal for stop-triggered Obsidian recording. Press Tab to autocomplete terminal commands.
            Configure llm_output.paste, llm_output.dump, and llm_output.bluetooth as clipboard, dump, or bluetooth-keyboard.
            Bluetooth push-to-talk is disabled by default; enable it in setup and choose a shortcut key.

            Options:
              --config PATH                Config file. Default: ~/.config/fluid-push-to-talk/config.json.
              --model-version v3|v2        ASR model version. v3 is multilingual, v2 is English-only.
              --language CODE|auto         Language hint. Default: de.
              --output-dir PATH            Directory for --save-recordings output.
              --save-recordings            Keep recordings instead of deleting temp files.
              --paste                      Paste final text into the focused field.
              --no-paste                   Disable paste behavior.
              --no-restore-clipboard       Leave dictated text on the clipboard after pasting.
              --paste-delay SECONDS        Wait before sending Cmd+V. Default: 0.1.
              --restore-clipboard-delay S  Wait before restoring clipboard. Default: 0.5.
              --test-command-information T Run command-result generation for test input.
              --test-command T             Command used with --test-command-information.
              --test-bluetooth-keyboard T  Send text through the configured ESP32 keyboard.
              -h, --help                   Show this help.

            Setup and config:
              setup                         Run the guided onboarding wizard.
              config                        Open the interactive configuration menu.
              config show                   Print a masked configuration summary.
              config doctor                 Check config, API key, Bluetooth, paths, and permissions.
              config reset --yes             Hard reset user config, support files, and local .env.
            """
        )
    }
}

enum CliError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidValue(String)

    var description: String {
        switch self {
        case let .invalidArgument(argument):
            return "Invalid argument: \(argument)"
        case let .invalidValue(message):
            return message
        }
    }
}
