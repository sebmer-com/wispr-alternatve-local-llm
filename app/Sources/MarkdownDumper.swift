import Foundation

final class MarkdownDumper: @unchecked Sendable {
    private let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    func dump(transcript: String) async throws -> URL {
        try dumpRaw(transcript)
    }

    func dumpRaw(_ text: String) throws -> URL {
        try write(text)
        return config.dump.markdownURL
    }

    private func write(_ markdown: String) throws {
        let fileURL = config.dump.markdownURL
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let entry = formatEntry(markdown)
        let data = entry.data(using: .utf8) ?? Data()

        if config.dump.append, FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func formatEntry(_ markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.dump.includeTimestamp else {
            return "\n\n\(trimmed)\n"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\n\n\(formatter.string(from: Date()))\n\(trimmed)\n"
    }
}
