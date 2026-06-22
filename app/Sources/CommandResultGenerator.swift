import Foundation

final class CommandResultGenerator: @unchecked Sendable {
    private let config: AppConfig
    private let skillCallingService: SkillCallingService
    private let llmClient: CommandLLMClient

    init(
        config: AppConfig,
        llmClient: CommandLLMClient,
        skillCallingService: SkillCallingService? = nil
    ) {
        self.config = config
        self.llmClient = llmClient
        self.skillCallingService = skillCallingService ?? SkillCallingService(config: config)
    }

    func generate(information: String, command: String) async throws -> String {
        let request = normalizedRequest(information: information, command: command)
        guard config.localLLM.canGenerateCommands else {
            let skillContext = skillCallingService.buildContext(
                information: request.information,
                command: request.command
            )
            log("command LLM disabled; using fallback result")
            return skillContext.toolFallback ?? request.fallback
        }

        let skillContext = await skillCallingService.buildContext(
            information: request.information,
            command: request.command,
            llmClient: llmClient,
            systemPrompt: config.prompts.coreCommand.system
        )
        if let finalResult = skillContext.finalResult {
            return finalResult
        }

        do {
            let startedAt = Date()
            log("sending command LLM request to \(llmClient.displayName)...")
            let prompt = commandPrompt(
                information: request.information,
                command: request.command,
                skillContext: skillContext.renderedContext
            )
            LLMDebugLogger.logPrompt(prompt, label: "core-command", config: config)
            let content = try await llmClient.complete(
                systemPrompt: config.prompts.coreCommand.system,
                userPrompt: prompt
            )
            guard !content.isEmpty else {
                throw CliError.invalidValue("command LLM returned an empty response")
            }
            log(
                "command LLM response received in \(formatSeconds(Date().timeIntervalSince(startedAt))) (\(content.count) chars)"
            )
            return content
        } catch {
            fputs(
                "command LLM unavailable for command result; using fallback text: \(error)\n",
                stderr
            )
            return skillContext.toolFallback ?? request.fallback
        }
    }

    private struct CommandRequest {
        let information: String
        let command: String
        let fallback: String
    }

    private func normalizedRequest(information: String, command: String) -> CommandRequest {
        if looksLikeAnswerInstruction(information), looksLikeStandaloneQuestion(command) {
            log("command request normalized: using command segment as question")
            let normalizedQuestion = canonicalStandaloneQuestion(command)
            return CommandRequest(
                information: normalizedQuestion,
                command: information,
                fallback: command
            )
        }
        return CommandRequest(
            information: canonicalStandaloneQuestion(information),
            command: command,
            fallback: information
        )
    }

    private func looksLikeAnswerInstruction(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count <= 80 else {
            return false
        }
        let phrases = [
            "beantworte",
            "beantwortet",
            "antwort",
            "answer",
            "frage",
            "question",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private func looksLikeStandaloneQuestion(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, normalized.count <= 160 else {
            return false
        }
        if normalized.hasSuffix("?") {
            return true
        }
        let starts = [
            "was ",
            "wer ",
            "wie ",
            "wo ",
            "wann ",
            "warum ",
            "wieso ",
            "weshalb ",
            "what ",
            "who ",
            "how ",
            "where ",
            "when ",
            "why ",
        ]
        return starts.contains { normalized.hasPrefix($0) }
    }

    private func canonicalStandaloneQuestion(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard normalized.hasPrefix("was sind "), normalized.count <= 80 else {
            return text
        }
        var subject = String(trimmed.dropFirst("Was sind ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.hasSuffix("?") {
            subject.removeLast()
        }
        subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else {
            return text
        }
        return "Erkläre kurz: \(subject)."
    }

    private func commandPrompt(information: String, command: String, skillContext: String?) -> String {
        let promptConfig = config.prompts.coreCommand
        if let skillContext {
            return renderPromptTemplate(
                promptConfig.userTemplateWithSkillContext,
                values: [
                    "command": command,
                    "information": information,
                    "skill_context": skillContext,
                ]
            )
        }

        return renderPromptTemplate(
            promptConfig.userTemplate,
            values: [
                "command": command,
                "information": information,
            ]
        )
    }

    private func renderPromptTemplate(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { rendered, item in
            rendered.replacingOccurrences(of: "{{\(item.key)}}", with: item.value)
        }
    }
}
