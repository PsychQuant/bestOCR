import ArgumentParser
import BestOCRKit
import Foundation

struct Consensus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Multi-engine consensus OCR: run several engines over the same input, "
            + "align items (line-primary, table cells split), and adjudicate with a "
            + "Dawid-Skene-lite estimator. Writes <stem>.consensus.md (transcript, "
            + "low-consensus items marked ⚠) and <stem>.consensus.json (per-engine "
            + "competence + low-consensus review list).")

    /// Optional only so `--list-adjudicators` can run without a file.
    /// Absence is validated in `run()` with the same message ArgumentParser
    /// would have produced, so normal usage sees no UX regression.
    @Argument(help: "Input file (pdf, png, jpg, jpeg, tiff, heic, bmp).")
    var input: String?

    @Option(help: "Comma-separated engine ids (default: every available local engine; needs ≥2).")
    var engines: String = ""

    @Option(help: "Output directory for <stem>.consensus.{md,json}.")
    var out: String = "."

    @Option(help: "Render DPI for PDF inputs.")
    var dpi: Double = 150

    @Option(help: "Page spec for PDFs, e.g. \"1-3,7\" (default: all pages).")
    var pages: String = ""

    @Option(help: "Comma-separated language preference, e.g. \"zh-Hant,en\".")
    var lang: String = ""

    @Option(name: .customLong("doc-type"),
            help: "Workload label (e.g. math_pdf, scanned_doc, gov_doc).")
    var docType: String = "unspecified"

    @Option(help: "Adjudicator id: ds-lite (default), majority, ds-full, prior-weighted. See --list-adjudicators — they estimate DIFFERENT things and their numbers are not comparable.")
    var adjudicator: String = "ds-lite"

    @Flag(name: .customLong("list-adjudicators"),
          help: "Print the adjudicators and when each fits, then exit.")
    var listAdjudicators = false

    mutating func run() async throws {
        if listAdjudicators {
            // Tradeoffs, never a ranking — a single ordering would imply these
            // models measure the same thing (#17 phase 6).
            for entry in AdjudicatorRegistry.catalogue {
                print("\(entry.id)\n    \(entry.guidance)")
            }
            print("\nEach adjudicator's output is a DISTINCT estimand "
                  + "(consensus.<id>.<quantity>@v1) — never cross-rank them.")
            return
        }
        guard let input else {
            throw ValidationError("Missing expected argument '<input>'. "
                                  + "(Only --list-adjudicators runs without one.)")
        }
        let registry = EngineRegistry.standard()
        var ids = engines.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if ids.isEmpty {
            for (engine, availability) in await registry.probeAll() {
                if case .available = availability, engine.family != .cloudReference {
                    ids.append(engine.id)
                }
            }
        }
        let languages = lang.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let summary = try await ConsensusPipeline.execute(
            inputPath: input, engineIDs: ids, dpi: dpi, pageSpec: pages,
            languages: languages, docType: docType,
            outDir: URL(fileURLWithPath: out), registry: registry,
            runLog: .default(), adjudicatorID: adjudicator)

        print("engines: \(summary.engines.joined(separator: ", "))")
        for (id, reason) in summary.skipped.sorted(by: { $0.key < $1.key }) {
            print("skipped: \(id) — \(reason)")
        }
        let est = summary.estimate
        print("adjudicator: \(est.adjudicator)")
        let rounds = est.diagnostics.iterations.map { " — \($0) iterations" } ?? ""
        print("items: \(est.items.count) (\(est.items.filter(\.lowConsensus).count) low-consensus)\(rounds)")
        // nil = this adjudicator has no competence notion; say so rather than
        // printing an empty list that reads like "everyone scored nothing" (#17).
        if let competence = est.diagnostics.overallCompetence {
            for (id, c) in competence.sorted(by: { $0.value > $1.value }) {
                print(String(format: "competence: %@ %.3f", id, c))
            }
        } else {
            print("competence: n/a — \(est.adjudicator) has no competence model")
        }
        print("transcript: \(summary.outputMarkdown.path)")
        print("report: \(summary.outputReport.path)")
        print("run-id: \(summary.runID) (promote with: bestocr evidence ingest \(summary.runID.prefix(8)))")
        if summary.overwrote {
            print("note: overwrote existing consensus artifacts for this stem/out-dir")
        }
    }
}
