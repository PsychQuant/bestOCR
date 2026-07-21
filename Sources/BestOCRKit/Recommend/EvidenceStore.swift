import Foundation

/// One measured row per evidence/schema.md — estimand × condition × tier.
public struct EvidenceRow: Codable, Sendable {
    public let estimand: String
    public let value: Double
    public let condition: ConditionTuple
    public let tier: String       // "T1" / "T2" / "T3"
    public let source: String
    public let caveat: String?

    public init(estimand: String, value: Double, condition: ConditionTuple,
                tier: String, source: String, caveat: String? = nil) {
        self.estimand = estimand
        self.value = value
        self.condition = condition
        self.tier = tier
        self.source = source
        self.caveat = caveat
    }
}

/// Read-only JSONL store of evidence rows (spec §6.2: writes happen only via
/// the explicit ingest gate, which lands in M4).
public struct EvidenceStore: Sendable {
    public let rows: [EvidenceRow]

    public init(rows: [EvidenceRow]) {
        self.rows = rows
    }

    /// `BESTOCR_EVIDENCE` env override, else `evidence/rows.jsonl` under CWD
    /// (the repo layout; other callers set the env).
    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["BESTOCR_EVIDENCE"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "evidence/rows.jsonl")
    }

    /// Absent file → empty store (the honest evidence-pending path).
    /// A malformed line is an error, not a skip — bad evidence must be loud.
    public static func load(from url: URL) throws -> EvidenceStore {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EvidenceStore(rows: [])
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var rows: [EvidenceRow] = []
        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                rows.append(try decoder.decode(EvidenceRow.self, from: Data(line.utf8)))
            } catch {
                throw OCREngineError(engine: "evidence",
                                     message: "\(url.path):\(index + 1): malformed evidence row — \(error.localizedDescription)")
            }
        }
        return EvidenceStore(rows: rows)
    }

    public func rows(docType: String) -> [EvidenceRow] {
        rows.filter { $0.condition.docType == docType }
    }
}
