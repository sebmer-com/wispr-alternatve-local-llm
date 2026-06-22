import AppKit
import Foundation

struct HermesAgentResult {
    let output: String
    let logURL: URL
    let sessionID: String?
    let runID: String
}

private struct HermesTerminalSessionState: Codable {
    let sessionName: String
    let windowID: Int
    let tabIndex: Int
    let marker: String
    let updatedAt: Date
}

private struct HermesVoiceSessionState: Codable {
    let sessionName: String
    let sessionID: String
    let updatedAt: Date
}

private struct HermesSessionExport: Decodable {
    let messages: [HermesSessionMessage]
}

private struct HermesSessionMessage: Decodable {
    let role: String
    let content: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
    }
}

final class HermesAgentRunner: @unchecked Sendable {
    private let config: HermesAgentConfig
    private let fileManager = FileManager.default

    init(config: HermesAgentConfig) {
        self.config = config
    }

    func run(information: String, instruction: String, screenshotURL: URL?) async throws -> HermesAgentResult {
        guard config.enabled else {
            throw CliError.invalidValue("Hermes agent mode is disabled in config")
        }

        let clipboard = currentClipboardText()
        let runID = Self.makeRunID()
        let prompt = Self.makePrompt(
            information: information,
            instruction: instruction,
            clipboard: clipboard,
            screenshotURL: screenshotURL,
            runID: runID
        )
        let logURL = try ensureLogFile()
        try appendLog("\n===== Hermes voice agent run \(Date()) =====\n", to: logURL)
        try appendLog("[run id]\n\(runID)\n\n", to: logURL)
        try appendLog("[information]\n\(information.isEmpty ? "[empty]" : information)\n\n", to: logURL)
        try appendLog("[instruction]\n\(instruction.isEmpty ? "[empty]" : instruction)\n\n", to: logURL)
        try appendLog("[clipboard]\n\(clipboard.isEmpty ? "[empty]" : clipboard)\n\n", to: logURL)

        do {
            let sessionID = try ensureNamedVoiceSession(logURL: logURL)
            try appendLog("[command]\nforeground Hermes --resume \(sessionID), paste prompt, wait for exported response\n\n", to: logURL)
            try foregroundSessionAndSubmit(prompt: prompt, sessionID: sessionID)
            try appendLog("[foreground]\nHermes opened in foreground and prompt submitted.\n\n", to: logURL)
            fputs("Hermes opened in foreground; waiting for visible session response\n", stderr)
            let output = try waitForAssistantOutput(sessionID: sessionID, runID: runID, logURL: logURL)
            try appendLog("[hermes output]\n\(output.isEmpty ? "[empty]" : output)\n", to: logURL)
            return HermesAgentResult(output: output, logURL: logURL, sessionID: sessionID, runID: runID)
        } catch {
            try? appendLog("[hermes completed with error]\n\(error)\n", to: logURL)
            throw error
        }
    }

    private static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "LOCAL_AUDIO_HERMES_RUN_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8))"
    }

    private static func makePrompt(
        information: String,
        instruction: String,
        clipboard: String,
        screenshotURL: URL?,
        runID: String
    ) -> String {
        """
        You are Hermes Agent being invoked from a local push-to-talk dictation shortcut.

        Local Audio run ID:
        \(runID)

        Context transcript:
        \(information.isEmpty ? "[No context transcript was captured.]" : information)

        Current clipboard text:
        \(clipboard.isEmpty ? "[Clipboard is empty or does not contain plain text.]" : clipboard)

        Screenshot context:
        \(screenshotURL?.path ?? "[No screenshot was captured.]")

        User instruction:
        \(instruction)

        Decide semantically whether the user wants a follow-up, revision, reset, or standalone task. Use your own reasoning and available session context; the local audio app does not classify this for you. If the task should stand alone, avoid unnecessary dependence on prior context. If the task should continue or revise prior work, use the relevant context, including the clipboard when it is relevant. Do not expose this decision process. Execute the instruction using available tools if needed. Return the final result only. Keep the answer concise unless the user explicitly asks for detail.
        """
    }

    private func currentClipboardText(limit: Int = 20_000) -> String {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        return "\(prefix)\n[Clipboard truncated to \(limit) characters.]"
    }

    private func ensureLogFile() throws -> URL {
        let dir = URL(fileURLWithPath: "~/Library/Application Support/fluid-push-to-talk".expandingTilde, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hermes-agent.log")
        if !fileManager.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        return url
    }

    private func appendLog(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func foregroundSessionAndSubmit(prompt: String, sessionID: String) throws {
        copyPromptToClipboard(prompt)
        guard config.foregroundTerminal else {
            throw CliError.invalidValue("Hermes foreground Terminal is disabled; prompt copied to clipboard")
        }

        let marker = currentInteractiveSessionMarker()
        let state = loadTerminalSessionState(expectedMarker: marker)
        let escapedMarker = appleScriptString(marker)
        let expectedWindowID = state?.windowID ?? 0
        let expectedTabIndex = state?.tabIndex ?? 0
        let command = interactiveSessionCommand(marker: marker, sessionID: sessionID)
        let escapedCommand = appleScriptString(command)
        let script = """
        tell application "Terminal"
          activate
          set sessionMarker to "\(escapedMarker)"
          set expectedWindowID to \(expectedWindowID)
          set expectedTabIndex to \(expectedTabIndex)
          set reusedExistingTab to false
          set foundWindowID to 0
          set foundTabIndex to 0

          if expectedWindowID is not 0 and expectedTabIndex is not 0 then
            repeat with windowIndex from 1 to (count of windows)
              set terminalWindow to window windowIndex
              if (id of terminalWindow) is expectedWindowID then
                if (count of tabs of terminalWindow) is greater than or equal to expectedTabIndex then
                  set tabContents to contents of tab expectedTabIndex of terminalWindow
                  set tabCustomTitle to custom title of tab expectedTabIndex of terminalWindow
                  if (tabContents contains sessionMarker) or (tabCustomTitle contains sessionMarker) then
                    set reusedExistingTab to true
                    set foundWindowID to id of terminalWindow
                    set foundTabIndex to expectedTabIndex
                    set selected tab of terminalWindow to tab expectedTabIndex of terminalWindow
                    set index of terminalWindow to 1
                  end if
                end if
              end if
              if reusedExistingTab then exit repeat
            end repeat
          end if

          if reusedExistingTab is false then
            repeat with windowIndex from 1 to (count of windows)
              set terminalWindow to window windowIndex
              repeat with currentIndex from 1 to (count of tabs of terminalWindow)
                set tabContents to contents of tab currentIndex of terminalWindow
                set tabCustomTitle to custom title of tab currentIndex of terminalWindow
                if (tabContents contains sessionMarker) or (tabCustomTitle contains sessionMarker) then
                  set reusedExistingTab to true
                  set foundWindowID to id of terminalWindow
                  set foundTabIndex to currentIndex
                  set selected tab of terminalWindow to tab currentIndex of terminalWindow
                  set index of terminalWindow to 1
                  exit repeat
                end if
              end repeat
              if reusedExistingTab then exit repeat
            end repeat
          end if

          if reusedExistingTab is false then
            do script "\(escapedCommand)"
            delay 1
            set terminalWindow to front window
            set foundWindowID to id of terminalWindow
            set foundTabIndex to 0
            repeat 30 times
              repeat with currentIndex from 1 to (count of tabs of terminalWindow)
                set tabContents to contents of tab currentIndex of terminalWindow
                set tabCustomTitle to custom title of tab currentIndex of terminalWindow
                if (tabContents contains sessionMarker) or (tabCustomTitle contains sessionMarker) then
                  set foundTabIndex to currentIndex
                  set selected tab of terminalWindow to tab currentIndex of terminalWindow
                  set index of terminalWindow to 1
                  exit repeat
                end if
              end repeat
              if foundTabIndex is not 0 then exit repeat
              delay 0.2
            end repeat
            if foundTabIndex is 0 then set foundTabIndex to (count of tabs of terminalWindow)
          end if

          if foundWindowID is not 0 then
            repeat with windowIndex from 1 to (count of windows)
              set terminalWindow to window windowIndex
              if (id of terminalWindow) is foundWindowID then
                set index of terminalWindow to 1
                if foundTabIndex is not 0 then set selected tab of terminalWindow to tab foundTabIndex of terminalWindow
                exit repeat
              end if
            end repeat
          end if

          set sessionReady to false
          repeat 60 times
            set terminalWindow to front window
            set tabContents to contents of selected tab of terminalWindow
            if (tabContents contains "Welcome to Poseidon Agent") or (tabContents contains "Type your message") or (tabContents contains "Poseidon-Agent") then
              set sessionReady to true
              exit repeat
            end if
            delay 0.2
          end repeat

          set scriptOutput to (foundWindowID as text) & "|" & (foundTabIndex as text) & "|" & (sessionReady as text)
        end tell

        if sessionReady then
          tell application "System Events"
            tell process "Terminal"
              set frontmost to true
              keystroke "v" using command down
              key code 36
            end tell
          end tell
        end if

        return scriptOutput
        """

        guard let output = runAppleScript(script) else {
            throw CliError.invalidValue("Hermes foreground prompt paste failed; prompt copied to clipboard")
        }
        saveTerminalSessionState(from: output, marker: marker)
        let parts = output.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.indices.contains(2), parts[2] == "true" else {
            throw CliError.invalidValue("Hermes foreground session did not become ready; prompt copied to clipboard")
        }
    }

    private func copyPromptToClipboard(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }

    private func waitForAssistantOutput(sessionID: String, runID: String, logURL: URL) throws -> String {
        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        var lastError: Error?

        while Date() < deadline {
            do {
                if let output = try exportAssistantOutput(sessionID: sessionID, runID: runID) {
                    return output
                }
            } catch {
                lastError = error
                try? appendLog("[session export poll error]\n\(error)\n\n", to: logURL)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }

        if let lastError {
            throw CliError.invalidValue("Hermes visible session did not return a result for \(runID) within \(Int(config.timeoutSeconds)) seconds; last export error: \(lastError)")
        }
        throw CliError.invalidValue("Hermes visible session did not return a result for \(runID) within \(Int(config.timeoutSeconds)) seconds")
    }

    private func exportAssistantOutput(sessionID: String, runID: String) throws -> String? {
        let (stdout, _) = try runHermesProcess(
            arguments: [config.executable, "sessions", "export", "--session-id", sessionID, "-"],
            timeout: min(10, config.timeoutSeconds)
        )
        guard let exported = decodeSessionExport(stdout) else {
            return nil
        }
        guard let userIndex = exported.messages.lastIndex(where: {
            $0.role.lowercased() == "user" && ($0.content?.contains(runID) ?? false)
        }) else {
            return nil
        }
        for message in exported.messages.dropFirst(userIndex + 1) {
            guard message.role.lowercased() == "assistant" else {
                continue
            }
            let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !content.isEmpty {
                return content
            }
        }
        return nil
    }

    private func decodeSessionExport(_ raw: String) -> HermesSessionExport? {
        let decoder = JSONDecoder()
        if let data = raw.data(using: .utf8),
           let exported = try? decoder.decode(HermesSessionExport.self, from: data) {
            return exported
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            guard line.contains("\"messages\""),
                  let data = String(line).data(using: .utf8),
                  let exported = try? decoder.decode(HermesSessionExport.self, from: data) else {
                continue
            }
            return exported
        }
        return nil
    }

    func foregroundInteractiveSession(sessionID: String? = nil) {
        if let sessionID, !sessionID.isEmpty {
            foregroundExactSession(sessionID: sessionID)
        } else {
            ensureInteractiveSession(foreground: true)
        }
    }

    private func foregroundExactSession(sessionID: String) {
        guard config.foregroundTerminal else {
            return
        }
        let marker = currentInteractiveSessionMarker()
        let command = interactiveSessionCommand(marker: marker, sessionID: sessionID)
        let escapedCommand = appleScriptString(command)
        let script = """
        tell application "Terminal"
          activate
          do script "\(escapedCommand)"
          delay 1
          set terminalWindow to front window
          return ((id of terminalWindow) as text) & "|" & ((count of tabs of terminalWindow) as text)
        end tell
        """
        guard let output = runAppleScript(script) else {
            return
        }
        saveTerminalSessionState(from: output, marker: marker)
    }

    private func ensureInteractiveSession(foreground: Bool) {
        guard config.foregroundTerminal else {
            return
        }
        do {
            try ensureNamedVoiceSession()
        } catch {
            fputs("Hermes named session bootstrap failed: \(error)\n", stderr)
        }
        let desiredMarker = currentInteractiveSessionMarker()
        let state = loadTerminalSessionState(expectedMarker: desiredMarker)
        let marker = state?.marker ?? desiredMarker
        let escapedMarker = appleScriptString(marker)
        let expectedWindowID = state?.windowID ?? 0
        let expectedTabIndex = state?.tabIndex ?? 0
        let command = interactiveSessionCommand(marker: marker, sessionID: nil)
        let escapedCommand = appleScriptString(command)
        let shouldForeground = foreground ? "true" : "false"
        let previousFrontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let escapedPreviousFrontBundleID = appleScriptString(previousFrontBundleID)
        let script = """
        tell application "Terminal"
          set shouldForegroundSession to \(shouldForeground)
          set sessionMarker to "\(escapedMarker)"
          set expectedWindowID to \(expectedWindowID)
          set expectedTabIndex to \(expectedTabIndex)
          set reusedExistingTab to false
          set foundWindowID to 0
          set foundTabIndex to 0

          if expectedWindowID is not 0 and expectedTabIndex is not 0 then
            repeat with windowIndex from 1 to (count of windows)
              set terminalWindow to window windowIndex
              if (id of terminalWindow) is expectedWindowID then
                if (count of tabs of terminalWindow) is greater than or equal to expectedTabIndex then
                  set tabContents to contents of tab expectedTabIndex of terminalWindow
                  set tabCustomTitle to custom title of tab expectedTabIndex of terminalWindow
                  if (tabContents contains sessionMarker) or (tabCustomTitle contains sessionMarker) then
                    set reusedExistingTab to true
                    set foundWindowID to id of terminalWindow
                    set foundTabIndex to expectedTabIndex
                    if shouldForegroundSession then
                      set selected tab of terminalWindow to tab expectedTabIndex of terminalWindow
                      set index of terminalWindow to 1
                    end if
                  end if
                end if
              end if
              if reusedExistingTab then exit repeat
            end repeat
          end if

          if reusedExistingTab is false then
            repeat with windowIndex from 1 to (count of windows)
              set terminalWindow to window windowIndex
              repeat with currentIndex from 1 to (count of tabs of terminalWindow)
                set tabContents to contents of tab currentIndex of terminalWindow
                set tabCustomTitle to custom title of tab currentIndex of terminalWindow
                if (tabContents contains sessionMarker) or (tabCustomTitle contains sessionMarker) then
                  set reusedExistingTab to true
                  set foundWindowID to id of terminalWindow
                  set foundTabIndex to currentIndex
                  if shouldForegroundSession then
                    set selected tab of terminalWindow to tab currentIndex of terminalWindow
                    set index of terminalWindow to 1
                  end if
                  exit repeat
                end if
              end repeat
              if reusedExistingTab then exit repeat
            end repeat
          end if

          if reusedExistingTab is false then
            do script "\(escapedCommand)"
            delay 1
            set terminalWindow to front window
            set foundWindowID to id of terminalWindow
            set foundTabIndex to 0
            repeat 10 times
              repeat with currentIndex from 1 to (count of tabs of terminalWindow)
                set tabContents to contents of tab currentIndex of terminalWindow
                set tabCustomTitle to custom title of tab currentIndex of terminalWindow
                if (tabContents contains sessionMarker) or (tabCustomTitle contains sessionMarker) then
                  set foundTabIndex to currentIndex
                  if shouldForegroundSession then
                    set selected tab of terminalWindow to tab currentIndex of terminalWindow
                    set index of terminalWindow to 1
                  end if
                  exit repeat
                end if
              end repeat
              if foundTabIndex is not 0 then exit repeat
              delay 0.2
            end repeat
            if foundTabIndex is 0 then set foundTabIndex to (count of tabs of terminalWindow)
          end if

          if shouldForegroundSession then
            activate
            if foundWindowID is not 0 then
              repeat with windowIndex from 1 to (count of windows)
                set terminalWindow to window windowIndex
                if (id of terminalWindow) is foundWindowID then
                  set index of terminalWindow to 1
                  if foundTabIndex is not 0 then set selected tab of terminalWindow to tab foundTabIndex of terminalWindow
                  exit repeat
                end if
              end repeat
            end if
          end if
          return (foundWindowID as text) & "|" & (foundTabIndex as text) & "|\(escapedPreviousFrontBundleID)"
        end tell
        """
        guard let output = runAppleScript(script) else {
            return
        }
        saveTerminalSessionState(from: output, marker: marker)
        if !foreground, let previousBundleID = terminalSessionOutputParts(output).previousBundleID {
            reactivateApplication(bundleIdentifier: previousBundleID)
        }
    }

    private func interactiveSessionCommand(marker: String, sessionID: String?) -> String {
        var commandParts: [String] = []
        if let workdir = config.resolvedWorkdir {
            commandParts.append("cd \(shellQuote(workdir))")
        }
        commandParts.append("printf '\\033]0;\(shellQuotePayload(marker))\\007'")
        commandParts.append("echo \(shellQuote(marker))")
        commandParts.append("echo 'Hermes interactive session: \(shellQuotePayload(config.sessionName))'")
        commandParts.append("echo 'Voice results are pasted back to the original app; this session stays alive for manual follow-up.'")
        if let sessionID, !sessionID.isEmpty {
            commandParts.append("exec \(shellQuote(config.executable)) --resume \(shellQuote(sessionID))")
        } else {
            commandParts.append("exec \(shellQuote(config.executable)) -c \(shellQuote(config.sessionName))")
        }
        return commandParts.joined(separator: "; ")
    }

    private func runAppleScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("Hermes Terminal AppleScript launch failed: \(error)\n", stderr)
            return nil
        }
        let stderrText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            if !stderrText.isEmpty {
                fputs("Hermes Terminal AppleScript failed: \(stderrText)\n", stderr)
            }
            return nil
        }
        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadTerminalSessionState(expectedMarker: String) -> HermesTerminalSessionState? {
        let url = terminalSessionStateURL()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(HermesTerminalSessionState.self, from: data),
              state.sessionName == config.sessionName,
              state.marker == expectedMarker else {
            return nil
        }
        return state
    }

    private func saveTerminalSessionState(from output: String, marker: String) {
        let parts = terminalSessionOutputParts(output)
        guard let windowID = parts.windowID,
              let tabIndex = parts.tabIndex,
              windowID > 0,
              tabIndex > 0 else {
            return
        }
        let state = HermesTerminalSessionState(
            sessionName: config.sessionName,
            windowID: windowID,
            tabIndex: tabIndex,
            marker: marker,
            updatedAt: Date()
        )
        let url = terminalSessionStateURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            fputs("Hermes Terminal session state save failed: \(error)\n", stderr)
        }
    }

    @discardableResult
    private func ensureNamedVoiceSession(logURL: URL? = nil) throws -> String {
        if let sessionID = loadVoiceSessionID() {
            if let logURL {
                try? appendLog("[session]\ncontinuing named Hermes session \(config.sessionName) (\(sessionID))\n\n", to: logURL)
            }
            return sessionID
        }

        if let sessionID = findNamedVoiceSessionID(logURL: logURL) {
            saveVoiceSessionID(sessionID)
            return sessionID
        }

        let seedPrompt = "Initialize the persistent local-audio voice-agent session. Reply exactly: LOCAL_AUDIO_VOICE_AGENT_READY"
        let (stdout, stderr) = try runHermesProcess(arguments: [
            config.executable,
            "chat",
            "-Q",
            "--yolo",
            "--accept-hooks",
            "-q",
            seedPrompt,
        ])
        if let logURL {
            try? appendLog("[session bootstrap output]\n\(stdout.isEmpty ? "[empty]" : stdout)\n\n", to: logURL)
            if !stderr.isEmpty {
                try? appendLog("[session bootstrap stderr]\n\(stderr)\n\n", to: logURL)
            }
        }
        guard let sessionID = extractSessionID(from: stderr) else {
            throw CliError.invalidValue("Hermes did not return a session_id while bootstrapping named session \(config.sessionName)")
        }
        saveVoiceSessionID(sessionID)
        renameSession(sessionID, to: config.sessionName, logURL: logURL)
        if let listedSessionID = findNamedVoiceSessionID(logURL: logURL) {
            saveVoiceSessionID(listedSessionID)
            return listedSessionID
        }
        return sessionID
    }

    private func findNamedVoiceSessionID(logURL: URL?) -> String? {
        do {
            let (stdout, stderr) = try runHermesProcess(
                arguments: [config.executable, "sessions", "list"],
                timeout: min(10, config.timeoutSeconds)
            )
            let output = stdout.isEmpty ? stderr : stdout
            for line in output.split(whereSeparator: \.isNewline) {
                let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("\(config.sessionName) ") || text == config.sessionName else {
                    continue
                }
                let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let candidate = parts.last, !candidate.isEmpty else {
                    continue
                }
                if let logURL {
                    try? appendLog("[session]\nfound named Hermes session \(config.sessionName) (\(candidate))\n\n", to: logURL)
                }
                return candidate
            }
            return nil
        } catch {
            if let logURL {
                try? appendLog("[session list error]\n\(error)\n\n", to: logURL)
            }
            return nil
        }
    }

    private func renameSession(_ sessionID: String, to title: String, logURL: URL?) {
        do {
            let (stdout, stderr) = try runHermesProcess(arguments: [config.executable, "sessions", "rename", sessionID, title])
            if let logURL {
                try? appendLog("[session rename]\n\(stdout.isEmpty ? stderr : stdout)\n\n", to: logURL)
            }
        } catch {
            if let logURL {
                try? appendLog("[session rename error]\n\(error)\n\n", to: logURL)
            }
        }
    }

    private func runHermesProcess(arguments: [String], timeout: TimeInterval? = nil) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let workdir = config.resolvedWorkdir {
            process.currentDirectoryURL = URL(fileURLWithPath: workdir, isDirectory: true)
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(timeout ?? config.timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 1)
            if process.isRunning { process.interrupt() }
            throw CliError.invalidValue("Hermes timed out after \(Int(timeout ?? config.timeoutSeconds)) seconds")
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw CliError.invalidValue("Hermes failed with status \(process.terminationStatus): \(stderr.isEmpty ? stdout : stderr)")
        }
        return (stdout, stderr)
    }

    private func currentInteractiveSessionMarker() -> String {
        "__LOCAL_AUDIO_HERMES_SESSION__: \(config.sessionName):named"
    }

    private func extractSessionID(from stderr: String) -> String? {
        for line in stderr.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("session_id:") else { continue }
            let value = String(trimmed.dropFirst("session_id:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func loadVoiceSessionID() -> String? {
        let url = voiceSessionStateURL()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(HermesVoiceSessionState.self, from: data),
              state.sessionName == config.sessionName,
              !state.sessionID.isEmpty else {
            return nil
        }
        return state.sessionID
    }

    private func saveVoiceSessionID(_ sessionID: String) {
        let state = HermesVoiceSessionState(sessionName: config.sessionName, sessionID: sessionID, updatedAt: Date())
        let url = voiceSessionStateURL()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            fputs("Hermes voice session state save failed: \(error)\n", stderr)
        }
    }

    private func voiceSessionStateURL() -> URL {
        URL(fileURLWithPath: "~/Library/Application Support/fluid-push-to-talk/hermes-voice-session.json".expandingTilde)
    }

    private func terminalSessionOutputParts(_ output: String) -> (windowID: Int?, tabIndex: Int?, previousBundleID: String?) {
        let parts = output.split(separator: "|", maxSplits: 2).map(String.init)
        return (
            parts.indices.contains(0) ? Int(parts[0]) : nil,
            parts.indices.contains(1) ? Int(parts[1]) : nil,
            parts.indices.contains(2) && !parts[2].isEmpty ? parts[2] : nil
        )
    }

    private func reactivateApplication(bundleIdentifier: String) {
        let escapedBundleID = appleScriptString(bundleIdentifier)
        _ = runAppleScript("""
        tell application id "\(escapedBundleID)" to activate
        """)
    }

    private func terminalSessionStateURL() -> URL {
        URL(fileURLWithPath: "~/Library/Application Support/fluid-push-to-talk/hermes-terminal-session.json".expandingTilde)
    }

    private func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func shellQuotePayload(_ value: String) -> String {
        value
            .replacingOccurrences(of: "'", with: "'\\''")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
