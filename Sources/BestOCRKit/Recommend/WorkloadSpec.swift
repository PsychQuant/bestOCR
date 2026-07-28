import Foundation

/// What the caller is asking for, structurally (document-assembly spec §7.2).
///
/// This is the **query** axis and it deliberately does not appear in
/// `ConditionTuple`: the tuple records what was measured (`doc_type`), not what
/// someone asked for. Conflating them would put a request into the evidence
/// record.
public enum DocumentClass: String, Sendable, CaseIterable {
    case unspecified
    case singleColumn = "single_column"
    case multiColumn = "multi_column"
    case tabular
    case mixed

    /// Accepts the raw value plus the hyphenated spelling a person actually
    /// types on a command line (`multi-column`). Shared by CLI and MCP so the
    /// two can never drift into accepting different words.
    public static func parse(_ raw: String) -> DocumentClass? {
        let normalized = raw.trimmingCharacters(in: .whitespaces)
            .lowercased().replacingOccurrences(of: "-", with: "_")
        return DocumentClass(rawValue: normalized)
    }

    /// Spec §7.3 — the classes that cannot be served by per-page transcription
    /// at all. `unspecified` and `singleColumn` impose no constraint, which is
    /// what keeps every pre-existing selection byte-identical.
    public var requiresAssembly: Bool {
        switch self {
        case .multiColumn, .tabular, .mixed: return true
        case .unspecified, .singleColumn: return false
        }
    }
}

/// What the caller wants OCRed and what they optimise for (spec §6.1).
public struct WorkloadSpec: Sendable {
    public enum Priority: String, Sendable, CaseIterable {
        case quality, speed, balanced
    }

    public let docType: String
    public let languages: [String]
    public let priority: Priority
    public let needsMath: Bool
    /// Defaulted so existing call sites (CLI, MCP, AutoRouter) keep compiling
    /// and keep behaving; each surface opts in explicitly.
    public let documentClass: DocumentClass

    public init(docType: String, languages: [String] = [],
                priority: Priority = .balanced, needsMath: Bool = false,
                documentClass: DocumentClass = .unspecified) {
        self.docType = docType
        self.languages = languages
        self.priority = priority
        self.needsMath = needsMath
        self.documentClass = documentClass
    }
}
