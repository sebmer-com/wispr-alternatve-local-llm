import Foundation

struct SkillDocument {
    let name: String
    let description: String
    let body: String
    let url: URL
    let tool: SkillTool?
}

struct SkillTool {
    let path: String
    let fallback: Bool
    let finalResult: Bool
    let timeoutSeconds: TimeInterval
}

struct SelectedSkill {
    let document: SkillDocument
    let score: Int
}

struct SkillCallContext {
    let selectedSkills: [SelectedSkill]
    let renderedContext: String?
    let toolFallback: String?
    let finalResult: String?
}
