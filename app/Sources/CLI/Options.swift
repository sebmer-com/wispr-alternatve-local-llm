import FluidAudio
import Foundation

struct Options {
    var configPath: URL?
    var config = AppConfig()
    var command = RuntimeCommand.run
    var testCommandInformation: String?
    var testCommand: String?
    var testCommandImages: [URL] = []
    var testHermesInstruction: String?
    var testHermesImages: [URL] = []
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
                options.config.asr.language = AsrLanguageResolver.normalizePreference(
                    try value(after: argument, in: arguments, at: &index)
                )
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
            case "--test-command-image":
                options.testCommandImages.append(
                    URL(fileURLWithPath: try value(after: argument, in: arguments, at: &index).expandingTilde)
                )
            case "--test-hermes-instruction":
                options.testHermesInstruction = try value(after: argument, in: arguments, at: &index)
            case "--test-hermes-image":
                options.testHermesImages.append(
                    URL(fileURLWithPath: try value(after: argument, in: arguments, at: &index).expandingTilde)
                )
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
        if !AsrLanguageResolver.isValidPreference(options.config.asr.language) {
            throw CliError.invalidValue(
                "--language must be system, auto, or a supported code: \(AsrLanguageResolver.supportedCodeList)"
            )
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
        if (options.testCommandInformation == nil) != (options.testCommand == nil) {
            throw CliError.invalidValue("--test-command-information and --test-command must be used together")
        }
        if options.testCommandImages.count > 5 {
            throw CliError.invalidValue("--test-command-image supports at most five images")
        }
        if let missingImage = options.testCommandImages.first(where: {
            !FileManager.default.fileExists(atPath: $0.path)
        }) {
            throw CliError.invalidValue("--test-command-image file does not exist: \(missingImage.path)")
        }
        if options.testHermesImages.count > 5 {
            throw CliError.invalidValue("--test-hermes-image supports at most five images")
        }
        if !options.testHermesImages.isEmpty, options.testHermesInstruction == nil {
            throw CliError.invalidValue("--test-hermes-image requires --test-hermes-instruction")
        }
        if let missingImage = options.testHermesImages.first(where: {
            !FileManager.default.fileExists(atPath: $0.path)
        }) {
            throw CliError.invalidValue("--test-hermes-image file does not exist: \(missingImage.path)")
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
            Release Option first while holding Command to start a spoken command with screenshot context. Release Command to send it to the configured provider and paste the result. Up to five screenshots may be attached.
            Release Command first while holding Option to finish normal local dictation; Hermes no longer uses this gesture.
            Control + Option is selected during setup: Markdown Dump writes the transcript plus optional P screenshots, while Hermes sends one spoken instruction plus optional P screenshots to a visible Hermes session.
            In Markdown mode, release Control first while holding Option to record a provider command. The provider receives text only; its result and the captured screenshots are written to Markdown.
            After launch, type go and stop in the app Terminal for stop-triggered Obsidian recording. Press Tab to autocomplete terminal commands.
            Choose OpenAI Responses with fixed gpt-5.6-luna, low reasoning, and low-detail screenshots, Cerebras with fixed gemma-4-31b, or Gemini with fixed gemini-3.5-flash. OpenClaw is not a runtime option.
            Bluetooth push-to-talk is disabled by default; enable it in setup and choose a shortcut key.

            Options:
              --config PATH                Config file. Default: ~/.config/fluid-push-to-talk/config.json.
              --model-version v3|v2        ASR model version. v3 is multilingual, v2 is English-only.
              --language CODE|system|auto  Language hint. Default: system.
              --output-dir PATH            Directory for --save-recordings output.
              --save-recordings            Keep recordings instead of deleting temp files.
              --paste                      Paste final text into the focused field.
              --no-paste                   Disable paste behavior.
              --no-restore-clipboard       Leave dictated text on the clipboard after pasting.
              --paste-delay SECONDS        Wait before sending Cmd+V. Default: 0.1.
              --restore-clipboard-delay S  Wait before restoring clipboard. Default: 0.5.
              --test-command-information T Run command-result generation for test input.
              --test-command T             Command used with --test-command-information.
              --test-command-image PATH    Optional screenshot sent with --test-command-information; up to five screenshots are supported by command mode.
              --test-hermes-instruction T  Send text through the real visible Hermes runner and print its exported result.
              --test-hermes-image PATH     Optional native Hermes image attachment; repeat up to five times.
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
