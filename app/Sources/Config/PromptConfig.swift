import Foundation

struct PromptConfig: Decodable {
    var coreCommand = CoreCommandPromptConfig()

    enum CodingKeys: String, CodingKey {
        case coreCommand = "core_command"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coreCommand = try container.decodeIfPresent(
            CoreCommandPromptConfig.self,
            forKey: .coreCommand
        ) ?? coreCommand
    }

    static func load(preferredURL: URL, fallbackURL: URL) throws -> PromptConfig {
        let fileManager = FileManager.default
        let url = fileManager.fileExists(atPath: preferredURL.path) ? preferredURL : fallbackURL
        guard fileManager.fileExists(atPath: url.path) else {
            throw CliError.invalidValue("prompt config missing at \(preferredURL.path) or \(fallbackURL.path)")
        }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(PromptConfig.self, from: data)
        try config.validate()
        return config
    }

    private func validate() throws {
        guard !coreCommand.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CliError.invalidValue("prompt config core_command.system must not be empty")
        }
        guard !coreCommand.userTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CliError.invalidValue("prompt config core_command.user_template must not be empty")
        }
        guard !coreCommand.userTemplateWithSkillContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CliError.invalidValue("prompt config core_command.user_template_with_skill_context must not be empty")
        }
    }
}

struct CoreCommandPromptConfig: Decodable {
    var system = ""
    var userTemplate = ""
    var userTemplateWithSkillContext = ""

    enum CodingKeys: String, CodingKey {
        case system
        case userTemplate = "user_template"
        case userTemplateWithSkillContext = "user_template_with_skill_context"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        system = try container.decodePromptStringIfPresent(forKey: .system) ?? system
        userTemplate = try container.decodePromptStringIfPresent(forKey: .userTemplate) ?? userTemplate
        userTemplateWithSkillContext = try container.decodePromptStringIfPresent(
            forKey: .userTemplateWithSkillContext
        ) ?? userTemplateWithSkillContext
    }
}

extension KeyedDecodingContainer {
    func decodePromptStringIfPresent(forKey key: Key) throws -> String? {
        if !contains(key) {
            return nil
        }

        if let stringValue = try? decode(String.self, forKey: key) {
            return stringValue
        }
        if let lines = try? decode([String].self, forKey: key) {
            return lines.joined(separator: "\n")
        }

        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a prompt string or an array of prompt lines."
            )
        )
    }
}
