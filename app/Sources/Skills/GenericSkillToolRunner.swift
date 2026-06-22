import Foundation

final class GenericSkillToolRunner: @unchecked Sendable {
    func run(
        _ tool: SkillTool,
        for document: SkillDocument,
        information: String,
        command: String,
        environmentValues: [String: String] = [:]
    ) throws -> String {
        let toolURL = resolveToolURL(tool.path, relativeTo: document.url.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: toolURL.path) else {
            throw CliError.invalidValue("skill tool missing at \(toolURL.path)")
        }

        let process = Process()
        if toolURL.pathExtension == "py" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", toolURL.path]
        } else {
            guard FileManager.default.isExecutableFile(atPath: toolURL.path) else {
                throw CliError.invalidValue("skill tool is not executable at \(toolURL.path)")
            }
            process.executableURL = toolURL
            process.arguments = []
        }

        var environment = ProcessInfo.processInfo.environment
        environment["FLUID_SKILL_NAME"] = document.name
        environment["FLUID_SKILL_COMMAND"] = command
        environment["FLUID_SKILL_INFORMATION"] = information
        for (key, value) in environmentValues {
            environment[key] = value
        }
        process.environment = environment
        process.currentDirectoryURL = document.url.deletingLastPathComponent()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let finished = wait(for: process, timeoutSeconds: tool.timeoutSeconds)
        if !finished {
            process.terminate()
            process.waitUntilExit()
            throw CliError.invalidValue("skill tool \(document.name) timed out after \(formatSeconds(tool.timeoutSeconds))")
        }

        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let errorOutput, !errorOutput.isEmpty {
            fputs("\(errorOutput)\n", stderr)
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw CliError.invalidValue("skill tool \(document.name) exited with status \(process.terminationStatus)")
        }
        guard !output.isEmpty else {
            throw CliError.invalidValue("skill tool \(document.name) returned no output")
        }

        log("skill tool \(document.name) output received (\(output.count) chars)")
        return output
    }

    private func resolveToolURL(_ path: String, relativeTo skillDirectory: URL) -> URL {
        let expanded = path.expandingTilde
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return skillDirectory.appendingPathComponent(expanded)
    }

    private func wait(for process: Process, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}
