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

    @Argument(help: "Input file (pdf, png, jpg, jpeg, tiff, heic, bmp).")
    var input: String

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

    mutating func run() async throws {
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
            runLog: .default())

        print("engines: \(summary.engines.joined(separator: ", "))")
        for (id, reason) in summary.skipped.sorted(by: { $0.key < $1.key }) {
            print("skipped: \(id) — \(reason)")
        }
        let est = summary.estimate
        print("items: \(est.items.count) (\(est.items.filter(\.lowConsensus).count) low-consensus) — \(est.iterations) iterations")
        for (id, c) in est.overallCompetence.sorted(by: { $0.value > $1.value }) {
            print(String(format: "competence: %@ %.3f", id, c))
        }
        print("transcript: \(summary.outputMarkdown.path)")
        print("report: \(summary.outputReport.path)")
        print("run-id: \(summary.runID) (promote with: bestocr evidence ingest \(summary.runID.prefix(8)))")
    }
}
