import Foundation

/// One run's provenance record (spec §6.2): metadata only — page text lives
/// in the output files. Nothing here auto-promotes to evidence/; the explicit
/// `evidence ingest` gate arrives in M4.
public struct RunLogEntry: Codable, Sendable {
    public struct PageStat: Codable, Sendable {
        public let page: Int
        public let seconds: Double
        public let thermalState: String
        public let degenerateFlagged: Bool
    }

    /// A quality measurement attached by `compare` (spec §6): the estimand is
    /// a named, versioned formula and `reference` names the referent (a cloud
    /// engine's model output — never ground truth). Optional so pre-quality
    /// runlog lines keep decoding.
    public struct QualityStat: Codable, Sendable {
        public let estimand: String    // e.g. Comparator.formulaID
        public let value: Double
        public let reference: String   // "cloud.claude/claude-opus-4-8"

        public init(estimand: String, value: Double, reference: String) {
            self.estimand = estimand
            self.value = value
            self.reference = reference
        }
    }

    public let id: String
    public let timestamp: String     // ISO8601
    public let input: String
    public let output: String
    public let engineID: String
    public let condition: ConditionTuple
    public let pages: [PageStat]
    public let quality: QualityStat?

    public init(from result: OCRResult, input: String, output: String,
                quality: QualityStat? = nil) {
        self.id = UUID().uuidString
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.input = input
        self.output = output
        self.engineID = result.engineID
        self.condition = result.condition
        self.pages = result.pages.map {
            PageStat(page: $0.page, seconds: $0.seconds,
                     thermalState: $0.thermalState,
                     degenerateFlagged: $0.degenerateFlagged)
        }
        self.quality = quality
    }
}

/// Append-only JSONL log at a fixed path (spec §6 data flow).
public struct RunLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `BESTOCR_RUNLOG` env override (tests, alternate stores), else
    /// `~/.bestocr/runlog.jsonl`.
    public static func `default`() -> RunLog {
        if let override = ProcessInfo.processInfo.environment["BESTOCR_RUNLOG"] {
            return RunLog(fileURL: URL(fileURLWithPath: override))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return RunLog(fileURL: home.appendingPathComponent(".bestocr/runlog.jsonl"))
    }

    public func append(_ entry: RunLogEntry) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry)
        line.append(Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL)
        }
    }
}
