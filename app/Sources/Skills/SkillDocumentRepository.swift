import Foundation

final class SkillDocumentRepository: @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func loadDocuments() -> [SkillDocument] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }

            return loadDocument(from: url.appendingPathComponent("SKILL.md"))
        }
    }

    private func loadDocument(from url: URL) -> SkillDocument? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else {
            return nil
        }

        let lines = raw.components(separatedBy: .newlines)
        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }

        let frontmatter = parseFrontmatter(lines[1..<closingIndex])
        let body = lines.dropFirst(closingIndex + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let name = frontmatter["name"], !name.isEmpty,
              let description = frontmatter["description"], !description.isEmpty else {
            return nil
        }

        return SkillDocument(
            name: name,
            description: description,
            body: body,
            url: url,
            tool: parseTool(from: frontmatter)
        )
    }

    private func parseFrontmatter(_ lines: ArraySlice<String>) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values
    }

    private func parseTool(from frontmatter: [String: String]) -> SkillTool? {
        guard let path = frontmatter["tool"], !path.isEmpty else {
            return nil
        }

        return SkillTool(
            path: path,
            fallback: boolValue(frontmatter["tool_fallback"]) ?? false,
            finalResult: boolValue(frontmatter["tool_final_result"]) ?? false,
            timeoutSeconds: timeIntervalValue(frontmatter["tool_timeout_seconds"]) ?? 10
        )
    }

    private func boolValue(_ raw: String?) -> Bool? {
        guard let raw else {
            return nil
        }

        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    private func timeIntervalValue(_ raw: String?) -> TimeInterval? {
        guard let raw else {
            return nil
        }
        return TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
