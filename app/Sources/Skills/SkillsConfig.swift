import Foundation

struct SkillsConfig: Codable {
    var enabled = true
    var directory = "skills"
    var maxSelected = 2
    var minimumScore = 2

    enum CodingKeys: String, CodingKey {
        case enabled
        case directory
        case maxSelected = "max_selected"
        case minimumScore = "minimum_score"
    }

    var directoryURL: URL {
        URL(fileURLWithPath: directory.expandingTilde, isDirectory: true)
    }
}
