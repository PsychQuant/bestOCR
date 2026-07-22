import ArgumentParser
import BestOCRKit
import Foundation

struct Evidence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evidence-store operations (explicit ingest gate).",
        subcommands: [Ingest.self]
    )

    struct Ingest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Promote one runlog entry to T2 evidence rows: speed.ms_per_page, plus the compare quality metric when the entry carries one. Explicit by design — nothing auto-promotes.")

        @Argument(help: "Run id from the runlog (full id or unique prefix).")
        var runID: String

        mutating func run() async throws {
            let entry: RunLogEntry
            do {
                entry = try EvidenceIngest.findEntry(id: runID, in: RunLog.default().fileURL)
            } catch let error as OCREngineError {
                throw ValidationError(error.errorDescription ?? "\(error)")
            }
            let rows = EvidenceIngest.rows(from: entry)
            guard !rows.isEmpty else {
                throw ValidationError("entry \(entry.id) has no pages — nothing to ingest")
            }
            let target = EvidenceStore.ingestTargetURL()
            try EvidenceIngest.append(rows, to: target)
            print("ingested \(rows.count) row(s) from runlog entry \(entry.id):")
            for row in rows {
                var line = "  \(row.estimand) = \(row.value) (\(row.tier), \(row.source))"
                if let caveat = row.caveat { line += " — caveat: \(caveat)" }
                print(line)
            }
            print("→ \(target.path)")
        }
    }
}
