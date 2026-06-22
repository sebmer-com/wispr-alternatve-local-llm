import Foundation

final class SkillCallingService: @unchecked Sendable {
    private let selector: GenericSkillSelector
    private let toolRunner: GenericSkillToolRunner
    private let toolEnvironment: [String: String]

    init(
        selector: GenericSkillSelector,
        toolRunner: GenericSkillToolRunner = GenericSkillToolRunner(),
        toolEnvironment: [String: String] = [:]
    ) {
        self.selector = selector
        self.toolRunner = toolRunner
        self.toolEnvironment = toolEnvironment
    }

    convenience init(config: SkillsConfig) {
        self.init(selector: GenericSkillSelector(config: config))
    }

    convenience init(config: AppConfig) {
        self.init(
            selector: GenericSkillSelector(config: config.skills),
            toolEnvironment: [
                "FLUID_OBSIDIAN_DAILY_NOTE": config.dump.markdownURL.path,
            ]
        )
    }

    func buildContext(information: String, command: String) -> SkillCallContext {
        buildContext(
            information: information,
            command: command,
            selectedSkills: selector.select(information: information, command: command)
        )
    }

    func buildContext(
        information: String,
        command: String,
        llmClient: CommandLLMClient,
        systemPrompt: String
    ) async -> SkillCallContext {
        let metadataSelected = selector.select(information: information, command: command)
        guard metadataSelected.isEmpty else {
            return buildContext(
                information: information,
                command: command,
                selectedSkills: metadataSelected
            )
        }

        let llmSelected = await selectSkillsWithLLM(
            information: information,
            command: command,
            llmClient: llmClient,
            systemPrompt: systemPrompt
        )
        return buildContext(
            information: information,
            command: command,
            selectedSkills: llmSelected
        )
    }

    private func buildContext(
        information: String,
        command: String,
        selectedSkills: [SelectedSkill]
    ) -> SkillCallContext {
        logSelection(selectedSkills)

        guard !selectedSkills.isEmpty else {
            return SkillCallContext(selectedSkills: [], renderedContext: nil, toolFallback: nil, finalResult: nil)
        }

        var toolFallbacks: [String] = []
        var finalResults: [String] = []
        let sections = selectedSkills.map { selected -> String in
            renderSection(
                for: selected,
                information: information,
                command: command,
                toolFallbacks: &toolFallbacks,
                finalResults: &finalResults
            )
        }

        let context = """
        Selected skills:
        \(sections.joined(separator: "\n\n"))
        """
        return SkillCallContext(
            selectedSkills: selectedSkills,
            renderedContext: context,
            toolFallback: toolFallbacks.first,
            finalResult: finalResults.first
        )
    }

    private func selectSkillsWithLLM(
        information: String,
        command: String,
        llmClient: CommandLLMClient,
        systemPrompt: String
    ) async -> [SelectedSkill] {
        let documents = selector.loadDocuments()
        guard !documents.isEmpty else {
            return []
        }
        guard shouldAskLLMForSkill(information: information, command: command, documents: documents) else {
            return []
        }

        log("skill selection: no metadata match; asking command LLM")
        let catalog = documents
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
        let prompt = """
        Select the skills needed for this request.
        Return only a JSON array of exact skill names, for example ["tasks"].
        Return [] if no skill should be used.
        Select side-effect skills only when the user explicitly asks to perform that action.

        Skills:
        \(catalog)

        Information:
        \(information)

        Command:
        \(command)
        """

        do {
            let response = try await llmClient.complete(
                systemPrompt: systemPrompt,
                userPrompt: prompt
            )
            let names = parseSkillNames(from: response)
            let selected = documents.compactMap { document -> SelectedSkill? in
                guard names.contains(document.name) else {
                    return nil
                }
                return SelectedSkill(document: document, score: 100)
            }
            if !selected.isEmpty {
                log("skill selection: command LLM selected \(selected.map { $0.document.name }.joined(separator: ", "))")
            }
            return selected
        } catch {
            fputs("skill selection LLM failed: \(error)\n", stderr)
            return []
        }
    }

    private func shouldAskLLMForSkill(
        information: String,
        command: String,
        documents: [SkillDocument]
    ) -> Bool {
        let query = normalized("\(command)\n\(information)")
        let triggers = [
            "skill",
            "task",
            "todo",
            "to do",
            "aufgabe",
            "erinnere",
            "erinnerung",
            "reminder",
            "greet",
            "gruss",
            "gruß",
            "wetter",
            "weather",
        ]
        if triggers.contains(where: { query.contains($0) }) {
            return true
        }
        return documents.contains { document in
            let name = normalized(document.name.replacingOccurrences(of: "-", with: " "))
            return !name.isEmpty && query.contains(name)
        }
    }

    private func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "de_DE")
        )
        .lowercased()
    }

    private func parseSkillNames(from response: String) -> Set<String> {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start <= end else {
            return []
        }
        let json = String(response[start...end])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return Set(array)
    }

    private func logSelection(_ selectedSkills: [SelectedSkill]) {
        if selectedSkills.isEmpty {
            log("skill selection: no matching skills")
            return
        }

        let summary = selectedSkills
            .map { "\($0.document.name)(score \($0.score))" }
            .joined(separator: ", ")
        log("skill selection: \(summary)")
    }

    private func renderSection(
        for selected: SelectedSkill,
        information: String,
        command: String,
        toolFallbacks: inout [String],
        finalResults: inout [String]
    ) -> String {
        let document = selected.document
        log("using skill: \(document.name) (\(document.url.path), score \(selected.score))")

        var section = """
        ## \(document.name)
        Source: \(document.url.path)
        Description: \(document.description)

        Instructions:
        \(document.body)
        """

        guard let tool = document.tool else {
            return section
        }

        do {
            let output = try toolRunner.run(
                tool,
                for: document,
                information: information,
                command: command,
                environmentValues: toolEnvironment
            )
            if tool.fallback {
                toolFallbacks.append(output)
            }
            if tool.finalResult {
                finalResults.append(output)
            }
            section += """

            Tool output:
            \(output)
            """
        } catch {
            fputs("skill tool \(document.name) failed: \(error)\n", stderr)
        }

        return section
    }
}
