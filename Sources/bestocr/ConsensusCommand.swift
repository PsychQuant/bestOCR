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
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if ids.isEmpty {
            for (engine, availability) in await registry.probeAll() {
                if case .available = availability, engine.family != .cloudReference {
                    ids.append(engine.id)
                }
            }
        }
        let languages = lang.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let summary = try await ConsensusPipeline.execute(
            inputPath: input, engineIDs: ids, dpi: dpi, pageSpec: pages,
            languages: languages, docType: docType,
            outDir: URL(fileURLWithPath: out), registry: registry,
            runLog: .default(), adjudicatorID: adjudicator)

        print("engines: \(summary.engines.joined(separator: ", "))")
        for (id, reason) in summary.skipped.sorted(by: { $0.key < $1.key }) {
            // "One line, one fact" — id AND reason are outside-influenced
            // (reason really carries multi-line adapter stderr; R2 NEW-1/2).
            print("skipped: \(ConsensusPipeline.oneLine(id)) — "
                  + ConsensusPipeline.oneLine(reason))
        }
        // #38: a refusal is a measurement outcome — say it first and plainly.
        if summary.refused {
            print("REFUSED: \(summary.refusalReason ?? "co-answer share below threshold")")
            print("No competence was estimated — the report carries the alignment")
            print("diagnostics (response-count distribution, agreement matrix).")
            // R1 F-10: on refusal the reader most needs to know which engines
            // the check ran WITHOUT — that lived only in the JSON.
            if let check = summary.singleConsensus, !check.excludedEngines.isEmpty {
                print("excluded: \(check.excludedEngines.joined(separator: ", "))"
                      + " — no co-answer data (not part of the refused check)")
            }
            // #13 F15c is END-TO-END: a refusal that replaced a previous
            // valid run's artifacts must say so here, not only in the
            // summary struct (R2 — four independent reviewers converged).
            if summary.overwrote {
                print("note: overwrote existing consensus artifacts for this stem/out-dir")
            }
            print("transcript: \(ConsensusPipeline.oneLine(summary.outputMarkdown.path))")
            print("report: \(ConsensusPipeline.oneLine(summary.outputReport.path))")
            return
        }
        let est = summary.estimate
        print("adjudicator: \(est.adjudicator)")
        // #39: the single-consensus check — competence below is only
        // meaningful if this held. untestable ≠ passed; both are disclosed.
        // No line at all is RESERVED for "no competence claimed" (majority);
        // an unchecked competence claim (rover) must say it is unchecked.
        if let check = summary.singleConsensus {
            var line: String
            switch check.verdict {
            case "passed":
                // Clamped rank-1 ratio is a clamp artifact, not a measurement
                // — read the RECORDED flag, never infer from magnitude
                // (R1 F-07 → R2 codex 4). The threshold appears on the
                // passed line because it is env-overridable and matters most
                // exactly when it was changed (R2 DA-1).
                let ratioText = check.ratioUnbounded == true
                    ? "unbounded (λ2 ≈ 0 — rank-1 agreement)"
                    : check.ratio.map { String(format: "%.2f", $0) } ?? "n/a"
                let thresholdText = check.minRatio.map {
                    String(format: " (threshold %.2f)", $0)
                } ?? ""
                line = "single-consensus: passed — eigenvalue ratio "
                    + ratioText + thresholdText
            default:
                line = "single-consensus: \(check.verdict) — \(check.reason ?? "unspecified")"
            }
            if !check.excludedEngines.isEmpty {
                line += " (excluded: \(check.excludedEngines.joined(separator: ", "))"
                    + " — no co-answer data)"
            }
            print(line)
        } else if AdjudicatorRegistry.isSequenceAdjudicator(est.adjudicator),
                  est.diagnostics.overallCompetence != nil {
            // R1 B2: rover reports competence but its confusion-network
            // alignment sits outside this check (#49) — the ranking below
            // carries an UNTESTED single-key assumption, and silence here
            // would read as "nothing claimed". Guard is the EXPLICIT
            // sequence-adjudicator predicate, not a competence-nil proxy —
            // the proxy was the very criterion #39 renamed away (R2 DA-2).
            print("single-consensus: not checked — \(est.adjudicator) reports "
                  + "competence but its alignment model is outside this check "
                  + "(#49); the single-key assumption is untested")
        }
        let rounds = est.diagnostics.iterations.map { " — \($0) iterations" } ?? ""
        // solo = single-engine items the aligner never grouped — NOT disputes
        // (#38: the ⚠ marks used to read as "engines disagreed here").
        let solo = est.items.filter { item in
            item.responses.values.filter { !$0.isEmpty }.count <= 1
        }.count
        print("items: \(est.items.count) (\(est.items.filter(\.lowConsensus).count) low-consensus, "
              + "of which \(solo) solo/unaligned — single response, not a dispute)\(rounds)")
        // nil = this adjudicator has no competence notion; say so rather than
        // printing an empty list that reads like "everyone scored nothing" (#17).
        if let competence = est.diagnostics.overallCompetence {
            let ns = est.diagnostics.informativeItems
            for (id, c) in competence.sorted(by: { $0.value > $1.value }) {
                // n makes a bare prior visibly different from a measurement (#38).
                let suffix = ns.map { counts -> String in
                    let n = counts[id] ?? 0
                    return n == 0 ? " (prior — no informative items)" : " (n=\(n))"
                } ?? ""
                print(String(format: "competence: %@ %.3f%@", id, c, suffix))
            }
        } else {
            print("competence: n/a — \(est.adjudicator) has no competence model")
        }
        print("transcript: \(ConsensusPipeline.oneLine(summary.outputMarkdown.path))")
        print("report: \(ConsensusPipeline.oneLine(summary.outputReport.path))")
        print("run-id: \(summary.runID) (promote with: bestocr evidence ingest \(summary.runID.prefix(8)))")
        if summary.overwrote {
            print("note: overwrote existing consensus artifacts for this stem/out-dir")
        }
    }
}
