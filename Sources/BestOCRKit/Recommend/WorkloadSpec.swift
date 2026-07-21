/// What the caller wants OCRed and what they optimise for (spec §6.1).
public struct WorkloadSpec: Sendable {
    public enum Priority: String, Sendable, CaseIterable {
        case quality, speed, balanced
    }

    public let docType: String
    public let languages: [String]
    public let priority: Priority
    public let needsMath: Bool

    public init(docType: String, languages: [String] = [],
                priority: Priority = .balanced, needsMath: Bool = false) {
        self.docType = docType
        self.languages = languages
        self.priority = priority
        self.needsMath = needsMath
    }
}
