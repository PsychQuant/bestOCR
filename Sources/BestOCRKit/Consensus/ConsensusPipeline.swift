import Foundation

/// Result of one consensus run (#11).
public struct ConsensusRunSummary: Sendable {
    public let outputMarkdown: URL
    public let outputReport: URL
    public let engines: [String]
    public let skipped: [String: String]   // engineID → reason
    public let estimate: ConsensusEstimate
    /// Runlog entry id (#12) — the handle `bestocr evidence ingest` takes.
    public let runID: String
    /// True when this run replaced existing consensus artifacts for the same
    /// stem/outDir (#13 F15c) — surfaced, never silent.
    public let overwrote: Bool
}

/// Multi-engine consensus flow (#11): run N engines over the same normalized
/// input → extract + align items per page → Dawid-Skene-lite adjudication →
/// consensus transcript + machine-readable report.
///
/// `adjudicate` and `writeOutputs` are pure/FS-local and unit-tested;
/// `execute` is the thin engine-running shell mirroring `RunPipeline` idioms.
public enum ConsensusPipeline {

    // MARK: - Pure core

    /// Page-wise extract + align across engines, then estimate.
    public static func adjudicate(results: [String: OCRResult]) -> ConsensusEstimate {
        var pages: Set<Int> = []
        for r in results.values { for p in r.pages { pages.insert(p.page) } }

        var allItems: [AlignedItem] = []
        for page in pages.sorted() {
            var extractions: [String: [ExtractedItem]] = [:]
            var degenerate: Set<String> = []
            for (engine, result) in results {
                guard let pageResult = result.pages.first(where: { $0.page == page }) else { continue }
                extractions[engine] = ItemExtractor.extract(page: page, text: pageResult.text)
                if pageResult.degenerateFlagged { degenerate.insert(engine) }
            }
            allItems.append(contentsOf: ConsensusAlignment.align(page: page, extractions: extractions,
                                                                 degenerate: degenerate))
        }
        return ConsensusEstimator.estimate(items: allItems)
    }

    // MARK: - Outputs

    /// Writes `<stem>.consensus.md` (transcript; low-consensus items prefixed
    /// with `⚠`) and `<stem>.consensus.json` (report). MVP limitation,
    /// documented: table structure is not reconstructed — cells appear as
    /// individual lines; the report is the primary artifact for review.
    public static func writeOutputs(estimate: ConsensusEstimate, engines: [String],
                                    skipped: [String: String], inputPath: String,
                                    outDir: URL) throws -> (markdown: URL, report: URL) {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent

        var lines: [String] = []
        var currentPage = Int.min
        for item in estimate.items.sorted(by: { ($0.key.page, $0.key.index) < ($1.key.page, $1.key.index) }) {
            if item.key.page != currentPage {
                if currentPage != Int.min { lines.append("\n---\n") }
                currentPage = item.key.page
            }
            lines.append(item.lowConsensus ? "⚠ \(item.consensusText)" : item.consensusText)
        }
        let mdURL = outDir.appendingPathComponent("\(stem).consensus.md")
        try lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)

        let report = ConsensusReport(estimate: estimate, engines: engines, skipped: skipped)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonURL = outDir.appendingPathComponent("\(stem).consensus.json")
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        return (mdURL, jsonURL)
    }

    // MARK: - Engine-running shell

    /// Runs the requested engines over one normalized input. Requires at
    /// least two available engines — consensus over one informant is not
    /// consensus (spec: CCT needs corroboration; ≥3 recommended, ≥2 hard floor).
    public static func execute(inputPath: String, engineIDs: [String], dpi: Double,
                               pageSpec: String, languages: [String], docType: String,
                               outDir: URL, registry: EngineRegistry,
                               runLog: RunLog) async throws -> ConsensusRunSummary {
        guard dpi.isFinite, dpi > 0 else {
            throw OCREngineError(engine: "consensus",
                                 message: "dpi must be a finite positive number (got \(dpi))")
        }
        var skipped: [String: String] = [:]
        var candidates: [any OCREngine] = []
        var seen = Set<String>()
        for id in engineIDs {
            // A duplicate id is the same informant — dedupe (order-preserving)
            // so the ≥2 floor counts informants, not list entries.
            guard seen.insert(id).inserted else { continue }
            // "consensus" is the reserved runlog marker EvidenceIngest
            // branches on — enforced here, not just asserted against
            // today's standard registry.
            if id == "consensus" {
                throw OCREngineError(engine: "consensus",
                                     message: "'consensus' is the reserved runlog marker id"
                                         + " — no engine may claim it")
            }
            guard let engine = registry.engine(id: id) else {
                skipped[id] = "unknown engine id"
                continue
            }
            // Privacy contract: consensus is local-only (SKILL: 文件不離機;
            // MCP openWorldHint: false). Cloud AND network-reaching engines
            // are refused loudly, never silently honored.
            if engine.family == .cloudReference || engine.capabilities.needsNetwork {
                throw OCREngineError(engine: "consensus",
                                     message: "cloud/network engine '\(id)' is not allowed in"
                                         + " consensus (local-only privacy contract) — use"
                                         + " `bestocr compare` for cloud-reference runs")
            }
            if case .unavailable(let reason, _) = await engine.probe() {
                skipped[id] = "unavailable: \(reason)"
                continue
            }
            candidates.append(engine)
        }
        guard candidates.count >= 2 else {
            let trail = skipped.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
            throw OCREngineError(engine: "consensus",
                                 message: "needs ≥2 available engines, got \(candidates.count)"
                                     + (trail.isEmpty ? "" : " — \(trail)"))
        }

        let normalized = try InputNormalizer.normalize(
            inputPath: inputPath, dpi: dpi, pageSpec: pageSpec, workDir: nil)
        defer { normalized.cleanup() }
        let request = OCRRequest(pages: normalized.pages, languages: languages,
                                 dpi: normalized.dpi, docType: docType)

        var results: [String: OCRResult] = [:]
        for engine in candidates {
            do {
                results[engine.id] = try await engine.recognize(request)
            } catch is CancellationError {
                // A cancelled job must stop, not keep running the remaining
                // engines and write outputs.
                throw CancellationError()
            } catch let error as OCREngineError {
                skipped[engine.id] = error.errorDescription ?? error.message
            } catch {
                skipped[engine.id] = String(describing: error)
            }
        }
        guard results.count >= 2 else {
            let trail = skipped.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
            throw OCREngineError(engine: "consensus",
                                 message: "fewer than 2 engines produced output — \(trail)")
        }

        let estimate = adjudicate(results: results)
        // Two OCRResults are not two effective informants: without a single
        // item co-answered with REAL content (empty placeholders abstain)
        // there is no consensus to report.
        guard estimate.items.contains(where: { item in
            item.responses.values.filter { !$0.isEmpty }.count >= 2
        }) else {
            throw OCREngineError(engine: "consensus",
                                 message: "no co-answered items across "
                                     + results.keys.sorted().joined(separator: ", ")
                                     + " — engines produced disjoint or empty extractions;"
                                     + " nothing to adjudicate")
        }
        // Overwrite is surfaced, never silent (#13 F15c) — replacing EITHER
        // artifact counts (a leftover report with no markdown is still an
        // overwrite).
        let stem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let overwrote = ["md", "json"].contains { ext in
            FileManager.default.fileExists(
                atPath: outDir.appendingPathComponent("\(stem).consensus.\(ext)").path)
        }
        let outputs = try writeOutputs(estimate: estimate,
                                       engines: results.keys.sorted(),
                                       skipped: skipped,
                                       inputPath: inputPath, outDir: outDir)

        // Provenance (#12): one explicit composite entry — the ensemble is
        // the unit under measurement. Promotion to evidence rows stays behind
        // the manual `evidence ingest <run-id>` gate.
        let share = estimate.items.isEmpty ? 0
            : Double(estimate.items.filter(\.lowConsensus).count) / Double(estimate.items.count)
        let entry = RunLogEntry(
            consensusOf: results, input: inputPath, output: outputs.markdown.path,
            quality: .init(estimand: "consensus.low_consensus_share@v1",
                           value: share,
                           reference: "engines=\(results.keys.sorted().joined(separator: "+"));converged=\(estimate.converged)"))
        try runLog.append(entry)

        return ConsensusRunSummary(outputMarkdown: outputs.markdown,
                                   outputReport: outputs.report,
                                   engines: results.keys.sorted(),
                                   skipped: skipped,
                                   estimate: estimate,
                                   runID: entry.id,
                                   overwrote: overwrote)
    }
}

/// JSON report — string keys throughout so the artifact is stable and
/// greppable (Swift dictionaries with enum keys encode as flat arrays).
struct ConsensusReport: Codable {
    struct LowConsensusItem: Codable {
        let page: Int
        let index: Int
        let kind: String
        let consensus: String
        let confidence: Double
        let responses: [String: String]
    }

    /// Report schema version: 2 = responses/consensus text are RAW engine
    /// renderings (v1 published normalized text). Legacy files decode as 1.
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let engines: [String]
    let skipped: [String: String]
    let itemCount: Int
    let iterations: Int
    let converged: Bool
    /// Share of items with ≥2 responses — the honest coverage number: how
    /// much of the transcript is actually corroborated vs single-engine.
    let coAnswerShare: Double
    /// Engines that produced output but zero alignable items — they appear
    /// in `engines` yet are absent from the competence maps; called out
    /// instead of silently missing.
    let enginesWithoutAlignedItems: [String]
    let overallCompetence: [String: Double]
    let competenceByKind: [String: [String: Double]]
    let agreement: [String: [String: Double]]
    let lowConsensus: [LowConsensusItem]

    enum CodingKeys: String, CodingKey {
        case engines, skipped, iterations, converged, agreement
        case schemaVersion = "schema_version"
        case itemCount = "item_count"
        case coAnswerShare = "co_answer_share"
        case enginesWithoutAlignedItems = "engines_without_aligned_items"
        case overallCompetence = "overall_competence"
        case competenceByKind = "competence_by_kind"
        case lowConsensus = "low_consensus"
    }

    /// Custom decode: fields added after the first release default instead
    /// of failing on old report files (`converged` → false, coverage → 0/[]).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.engines = try c.decode([String].self, forKey: .engines)
        self.skipped = try c.decode([String: String].self, forKey: .skipped)
        self.itemCount = try c.decode(Int.self, forKey: .itemCount)
        self.iterations = try c.decode(Int.self, forKey: .iterations)
        self.converged = try c.decodeIfPresent(Bool.self, forKey: .converged) ?? false
        self.coAnswerShare = try c.decodeIfPresent(Double.self, forKey: .coAnswerShare) ?? 0
        self.enginesWithoutAlignedItems =
            try c.decodeIfPresent([String].self, forKey: .enginesWithoutAlignedItems) ?? []
        self.overallCompetence = try c.decode([String: Double].self, forKey: .overallCompetence)
        self.competenceByKind = try c.decode([String: [String: Double]].self, forKey: .competenceByKind)
        self.agreement = try c.decode([String: [String: Double]].self, forKey: .agreement)
        self.lowConsensus = try c.decode([LowConsensusItem].self, forKey: .lowConsensus)
    }

    init(estimate: ConsensusEstimate, engines: [String], skipped: [String: String]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.engines = engines
        self.skipped = skipped
        self.itemCount = estimate.items.count
        self.iterations = estimate.iterations
        self.converged = estimate.converged
        self.coAnswerShare = estimate.items.isEmpty ? 0
            : Double(estimate.items.filter { item in
                item.responses.values.filter { !$0.isEmpty }.count >= 2
              }.count) / Double(estimate.items.count)
        self.enginesWithoutAlignedItems = engines.filter { engine in
            !estimate.items.contains { ($0.responses[engine]?.isEmpty == false) }
        }.sorted()
        self.overallCompetence = estimate.overallCompetence
        self.competenceByKind = estimate.competence.mapValues { kinds in
            Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.rawValue, $0.value) })
        }
        self.agreement = estimate.agreement
        self.lowConsensus = estimate.items.filter(\.lowConsensus).map {
            LowConsensusItem(page: $0.key.page, index: $0.key.index,
                             kind: $0.key.kind.rawValue,
                             consensus: $0.consensusText,
                             confidence: $0.confidence,
                             responses: $0.responses)
        }
    }
}
