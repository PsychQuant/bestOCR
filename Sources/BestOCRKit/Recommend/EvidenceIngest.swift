import Foundation

/// The explicit runlog → evidence gate (spec §6.2): nothing auto-promotes;
/// a human runs `bestocr evidence ingest <run-id>` and the selected entry
/// becomes T2 rows. M4 ingests `speed.ms_per_page` only — quality estimands
/// need a reference the runlog doesn't carry (documented limitation).
public enum EvidenceIngest {
    /// Convert one runlog entry into evidence rows. Thermal states other than
    /// nominal become a caveat (schema.md hard rule 5), never a silent drop.
    public static func rows(from entry: RunLogEntry) -> [EvidenceRow] {
        guard !entry.pages.isEmpty else { return [] }
        let meanSeconds = entry.pages.map(\.seconds).reduce(0, +) / Double(entry.pages.count)
        let hotPages = entry.pages.filter { $0.thermalState != "nominal" }
        let caveat: String? = hotPages.isEmpty ? nil
            : "thermal non-nominal on page(s) "
                + hotPages.map { "\($0.page) (\($0.thermalState))" }.joined(separator: ", ")
        return [
            EvidenceRow(estimand: "speed.ms_per_page",
                        value: (meanSeconds * 1000).rounded(),
                        condition: entry.condition,
                        tier: "T2",
                        source: "runlog:\(entry.id)",
                        caveat: caveat)
        ]
    }

    /// Locate a runlog entry by exact id or unique prefix. Missing or
    /// ambiguous ids fail loudly — evidence provenance must be exact.
    public static func findEntry(id: String, in runlogURL: URL) throws -> RunLogEntry {
        guard FileManager.default.fileExists(atPath: runlogURL.path) else {
            throw OCREngineError(engine: "evidence",
                                 message: "runlog not found: \(runlogURL.path)")
        }
        let content = try String(contentsOf: runlogURL, encoding: .utf8)
        let decoder = JSONDecoder()
        let entries = try content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(RunLogEntry.self, from: Data($0.utf8)) }
        let matches = entries.filter { $0.id == id || $0.id.hasPrefix(id) }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw OCREngineError(engine: "evidence",
                                 message: "no runlog entry matches '\(id)' in \(runlogURL.path)")
        default:
            throw OCREngineError(engine: "evidence",
                                 message: "'\(id)' is ambiguous (\(matches.count) matches) — use more of the id")
        }
    }

    /// Append rows as JSONL to the evidence file (created with parent dirs).
    public static func append(_ rows: [EvidenceRow], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(Data("\n".utf8))
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}
