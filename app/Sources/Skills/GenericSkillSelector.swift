import Foundation

final class GenericSkillSelector: @unchecked Sendable {
    private let config: SkillsConfig
    private let repository: SkillDocumentRepository

    init(config: SkillsConfig, repository: SkillDocumentRepository? = nil) {
        self.config = config
        self.repository = repository ?? SkillDocumentRepository(directoryURL: config.directoryURL)
    }

    func select(information: String, command: String) -> [SelectedSkill] {
        guard config.enabled else {
            return []
        }

        let documents = loadDocuments()
        guard !documents.isEmpty else {
            return []
        }

        let queryTokens = Set(Self.tokens(from: "\(command)\n\(information)"))
        guard !queryTokens.isEmpty else {
            return []
        }

        return documents.compactMap { document -> SelectedSkill? in
            let metadata = "\(document.name) \(document.description)"
            let metadataTokens = Set(Self.tokens(from: metadata))
            let score = queryTokens.intersection(metadataTokens).count + phraseBonus(for: document, command: command)
            guard score >= config.minimumScore else {
                return nil
            }
            return SelectedSkill(document: document, score: score)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.document.name < $1.document.name
            }
            return $0.score > $1.score
        }
        .prefix(max(0, config.maxSelected))
        .map { $0 }
    }

    func loadDocuments() -> [SkillDocument] {
        guard config.enabled else {
            return []
        }
        return repository.loadDocuments()
    }

    private func phraseBonus(for document: SkillDocument, command: String) -> Int {
        let normalizedCommand = Self.normalized(command)
        var score = 0
        for phrase in [document.name.replacingOccurrences(of: "-", with: " "), document.name] {
            let normalizedPhrase = Self.normalized(phrase)
            if !normalizedPhrase.isEmpty, normalizedCommand.contains(normalizedPhrase) {
                score += 2
            }
        }
        return score
    }

    private static func tokens(from text: String) -> [String] {
        let normalized = normalized(text)
        let stopWords: Set<String> = [
            "and", "the", "for", "with", "when", "use", "using", "into", "from", "that",
            "this", "asked", "ask", "please", "bitte", "der", "die", "das", "und", "oder",
            "mit", "fur", "für", "ein", "eine", "einen", "ist", "wie", "was", "nach"
        ]
        return normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "de_DE")
        )
        .lowercased()
    }
}
