import Foundation

struct TextReplacementConfig: Decodable {
    var enabled = true
    var replacements: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case enabled
        case replacements
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        replacements = try container.decodeIfPresent([String: String].self, forKey: .replacements) ?? replacements
    }

    static func load(preferredURL: URL, fallbackURL: URL) throws -> TextReplacementConfig {
        let fileManager = FileManager.default
        let url = fileManager.fileExists(atPath: preferredURL.path) ? preferredURL : fallbackURL
        guard fileManager.fileExists(atPath: url.path) else {
            return TextReplacementConfig()
        }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(TextReplacementConfig.self, from: data)
        try config.validate()
        return config
    }

    private func validate() throws {
        for key in replacements.keys {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CliError.invalidValue("text replacements must not contain empty source words")
            }
        }
    }
}

final class TextReplacementService: @unchecked Sendable {
    private let replacementsByNormalizedWord: [String: String]

    init(config: TextReplacementConfig) {
        guard config.enabled else {
            replacementsByNormalizedWord = [:]
            return
        }

        var values: [String: String] = [:]
        for (source, replacement) in config.replacements {
            let normalized = Self.normalized(source)
            guard !normalized.isEmpty else {
                continue
            }
            values[normalized] = replacement
        }
        replacementsByNormalizedWord = values
    }

    func rewrite(_ text: String) -> String {
        guard !replacementsByNormalizedWord.isEmpty, !text.isEmpty else {
            return text
        }

        var result = String()
        result.reserveCapacity(text.count)
        var word = String()
        word.reserveCapacity(32)

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                appendReplacement(for: word, to: &result)
                word.removeAll(keepingCapacity: true)
                result.unicodeScalars.append(scalar)
            }
        }
        appendReplacement(for: word, to: &result)
        return result
    }

    private func appendReplacement(for word: String, to result: inout String) {
        guard !word.isEmpty else {
            return
        }
        let replacement = replacementsByNormalizedWord[Self.normalized(word)] ?? word
        result += replacement
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "de_DE")
        )
        .lowercased()
    }
}
