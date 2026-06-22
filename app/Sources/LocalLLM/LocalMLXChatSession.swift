import Darwin
import Foundation

final class LocalMLXChatSession: CommandLLMClient, @unchecked Sendable {
    static let requiredModel = "prism-ml/Ternary-Bonsai-8B-mlx-2bit"

    private let config: LocalLLMConfig
    private let startLock = NSLock()
    private let requestLock = NSLock()
    private let outputCondition = NSCondition()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var output = ""
    private var stderrOutput = ""

    init(config: LocalLLMConfig) {
        self.config = config
    }

    var displayName: String {
        "local MLX llm-tool \(config.model)"
    }

    var requiresWarmUp: Bool {
        true
    }

    func warmUp(systemPrompt: String) async throws {
        try start(systemPrompt: systemPrompt)
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        try run(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    func start(systemPrompt: String) throws {
        startLock.lock()
        defer { startLock.unlock() }

        outputCondition.lock()
        let isRunning = process?.isRunning == true
        outputCondition.unlock()
        if isRunning {
            return
        }

        let executable = try resolveExecutable()
        let model = try resolveModel()

        let process = Process()
        process.executableURL = executable.url
        process.currentDirectoryURL = executable.workingDirectory
        process.arguments = executable.argumentPrefix + [
            "chat",
            "--download",
            config.download.expandingTilde,
            "--model",
            model,
            "--system",
            systemPrompt,
            "--max-tokens",
            String(config.maxTokens),
            "--temperature",
            String(config.temperature),
            "--cache-size",
            String(config.cacheSize),
            "--memory-size",
            String(config.memorySize),
        ]
        process.environment = executable.environment

        let stderrPipe = Pipe()
        let terminal = try makePseudoTerminal()
        process.standardInput = terminal.slaveInput
        process.standardOutput = terminal.slaveOutput
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] terminated in
            self?.outputCondition.lock()
            self?.stderrOutput += "\nlocal MLX llm-tool chat terminated with status \(terminated.terminationStatus)"
            self?.outputCondition.broadcast()
            self?.outputCondition.unlock()
        }

        outputCondition.lock()
        output = ""
        stderrOutput = ""
        self.process = process
        stdinHandle = terminal.master
        outputHandle = terminal.master
        outputCondition.unlock()

        terminal.master.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }
            self?.outputCondition.lock()
            self?.output += chunk
            self?.outputCondition.broadcast()
            self?.outputCondition.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }
            self?.outputCondition.lock()
            self?.stderrOutput += chunk
            self?.outputCondition.broadcast()
            self?.outputCondition.unlock()
        }

        try process.run()
        _ = try waitForPrompt(since: output.count)
    }

    func run(systemPrompt: String, userPrompt: String) throws -> String {
        requestLock.lock()
        defer { requestLock.unlock() }

        try start(systemPrompt: systemPrompt)

        resetChatSession()

        outputCondition.lock()
        let startOffset = output.count
        guard process?.isRunning == true, let stdinHandle else {
            let detail = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            outputCondition.unlock()
            throw CliError.invalidValue("mlx-run llm-tool chat is not running: \(detail)")
        }
        outputCondition.unlock()

        let promptLine = singleLinePrompt(userPrompt) + "\n"
        stdinHandle.write(Data(promptLine.utf8))

        let responseOutput = try waitForPrompt(since: startOffset)
        return extractResponse(from: responseOutput, sentPrompt: promptLine)
    }

    private func resetChatSession() {
        outputCondition.lock()
        let startOffset = output.count
        guard process?.isRunning == true, let stdinHandle else {
            outputCondition.unlock()
            return
        }
        outputCondition.unlock()

        stdinHandle.write(Data("/reset\n".utf8))
        _ = try? waitForPrompt(since: startOffset)
    }

    private func makePseudoTerminal() throws -> (master: FileHandle, slaveInput: FileHandle, slaveOutput: FileHandle) {
        var masterFD: Int32 = 0
        var slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw CliError.invalidValue("failed to create pseudo-terminal for mlx-run llm-tool chat: \(String(cString: strerror(errno)))")
        }

        let slaveInputFD = dup(slaveFD)
        let slaveOutputFD = dup(slaveFD)
        close(slaveFD)

        guard slaveInputFD >= 0, slaveOutputFD >= 0 else {
            close(masterFD)
            if slaveInputFD >= 0 {
                close(slaveInputFD)
            }
            if slaveOutputFD >= 0 {
                close(slaveOutputFD)
            }
            throw CliError.invalidValue("failed to duplicate pseudo-terminal handles for mlx-run llm-tool chat")
        }

        return (
            FileHandle(fileDescriptor: masterFD, closeOnDealloc: true),
            FileHandle(fileDescriptor: slaveInputFD, closeOnDealloc: true),
            FileHandle(fileDescriptor: slaveOutputFD, closeOnDealloc: true)
        )
    }

    private struct Executable {
        let url: URL
        let workingDirectory: URL
        let argumentPrefix: [String]
        let environment: [String: String]?
    }

    private func resolveExecutable() throws -> Executable {
        if let llmToolURL = config.llmToolURL,
           FileManager.default.isExecutableFile(atPath: llmToolURL.path) {
            let productDirectory = llmToolURL.deletingLastPathComponent()
            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_FRAMEWORK_PATH"] = [
                productDirectory.appendingPathComponent("PackageFrameworks").path,
                productDirectory.path,
            ].joined(separator: ":")
            return Executable(
                url: llmToolURL,
                workingDirectory: productDirectory,
                argumentPrefix: [],
                environment: environment
            )
        }

        let mlxRunURL = config.mlxRunURL
        guard FileManager.default.isExecutableFile(atPath: mlxRunURL.path) else {
            throw CliError.invalidValue("llm-tool is missing and mlx-run is missing or not executable at \(mlxRunURL.path)")
        }
        return Executable(
            url: mlxRunURL,
            workingDirectory: mlxRunURL.deletingLastPathComponent(),
            argumentPrefix: ["llm-tool"],
            environment: nil
        )
    }

    private func resolveModel() throws -> String {
        let model = config.model.expandingTilde
        let isBonsaiModel = model == Self.requiredModel
            || (model.isAbsolutePath && model.localizedCaseInsensitiveContains("Ternary-Bonsai-8B-mlx-2bit"))
        guard isBonsaiModel else {
            throw CliError.invalidValue("local LLM model must be \(Self.requiredModel); configured model is \(model)")
        }
        if model.isAbsolutePath {
            guard modelDirectoryIsUsable(URL(fileURLWithPath: model)) else {
                throw CliError.invalidValue("Bonsai model directory is incomplete: \(model)")
            }
            return model
        }

        let cacheName = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let cacheRoots = [
            URL(fileURLWithPath: config.download.expandingTilde),
            URL(fileURLWithPath: "~/.cache/huggingface/hub".expandingTilde),
        ]
        for cacheRoot in cacheRoots {
            if let snapshot = usableSnapshotDirectory(in: cacheRoot.appendingPathComponent(cacheName)) {
                return snapshot.path
            }
        }
        return model
    }

    private func usableSnapshotDirectory(in modelCacheURL: URL) -> URL? {
        let refsURL = modelCacheURL.appendingPathComponent("refs/main")
        if let revision = try? String(contentsOf: refsURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            let snapshot = modelCacheURL
                .appendingPathComponent("snapshots")
                .appendingPathComponent(revision)
            if modelDirectoryIsUsable(snapshot) {
                return snapshot
            }
        }

        let snapshotsURL = modelCacheURL.appendingPathComponent("snapshots")
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: snapshotsURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return snapshots.first(where: modelDirectoryIsUsable)
    }

    private func modelDirectoryIsUsable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path),
              fileManager.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path),
              let files = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return files.contains { $0.hasSuffix(".safetensors") }
    }

    private func waitForPrompt(since startOffset: Int) throws -> String {
        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        outputCondition.lock()
        defer { outputCondition.unlock() }

        while true {
            let segment = String(output.dropFirst(startOffset))
            if containsPromptMarker(segment) {
                return segment
            }
            if process?.isRunning != true {
                let detail = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                throw CliError.invalidValue("local MLX llm-tool chat exited before responding: \(detail)")
            }
            if Date() >= deadline {
                process?.terminate()
                throw CliError.invalidValue("local MLX llm-tool chat timed out after \(formatSeconds(config.timeoutSeconds))")
            }
            outputCondition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }

    private func containsPromptMarker(_ text: String) -> Bool {
        let stripped = stripANSI(text)
        return stripped.hasSuffix("> ") || stripped.contains("\n> ")
    }

    private func singleLinePrompt(_ prompt: String) -> String {
        prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func extractResponse(from stdout: String, sentPrompt: String) -> String {
        var text = normalizeTerminalNewlines(stripANSI(stdout))
        if text.hasPrefix("> ") {
            text = String(text.dropFirst(2))
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
        }
        let echoedPrompt = normalizeTerminalNewlines(sentPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(echoedPrompt) {
            text = String(text.dropFirst(echoedPrompt.count))
            if text.hasPrefix("\n") {
                text = String(text.dropFirst())
            }
        }
        if let trailingPrompt = text.range(of: "\n> ", options: .backwards) {
            text = String(text[..<trailingPrompt.lowerBound])
        } else if text.hasSuffix("> ") {
            text = String(text.dropLast(2))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
    }

    private func normalizeTerminalNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
