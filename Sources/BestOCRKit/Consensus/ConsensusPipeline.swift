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
    /// #38: the run refused to estimate — co-answer share below threshold
    /// means competence would measure alignment failure, not engine quality.
    /// A refusal is a legitimate measurement outcome, not a tool error.
    public let refused: Bool
    public let refusalReason: String?
    /// #39: single-consensus validity check outcome. nil = check did not run
    /// (majority, rover, or a co-answer refusal that never got that far).
    public let singleConsensus: SingleConsensusCheck?

    public init(outputMarkdown: URL, outputReport: URL, engines: [String],
                skipped: [String: String], estimate: ConsensusEstimate,
                runID: String, overwrote: Bool,
                refused: Bool = false, refusalReason: String? = nil,
                singleConsensus: SingleConsensusCheck? = nil) {
        self.outputMarkdown = outputMarkdown
        self.outputReport = outputReport
        self.engines = engines
        self.skipped = skipped
        self.estimate = estimate
        self.runID = runID
        self.overwrote = overwrote
        self.refused = refused
        self.refusalReason = refusalReason
        self.singleConsensus = singleConsensus
    }
}

/// Multi-engine consensus flow (#11): run N engines over the same normalized
/// input → extract + align items per page → co-answer gate (#38) →
/// single-consensus validity check (#39) → adjudication → consensus
/// transcript + machine-readable report.
///
/// The two gates are ordered, and the order is semantic, not incidental:
/// the co-answer gate refuses runs where alignment mostly never happened
/// (nothing to test), the single-consensus check refuses runs where the
/// aligned agreement structure is inconsistent with one latent answer key
/// (the pooling estimators' own validity condition). Only a run that passes
/// both reaches an estimator.
///
/// `adjudicate` and `writeOutputs` are pure/FS-local and unit-tested;
/// `execute` is the thin engine-running shell mirroring `RunPipeline` idioms.
public enum ConsensusPipeline {

    // MARK: - Pure core

    /// Sequence-adjudicator path (#17 phase 5): builds one confusion network
    /// per page from raw page text and combines the per-page estimates.
    ///
    /// Kept separate from `adjudicate(results:adjudicator:)` on purpose — the
    /// two consume genuinely different inputs, and collapsing them would force
    /// `AlignedItem` to carry a distinction it explicitly does not make.
    public static func adjudicateSequence(results: [String: OCRResult],
                                          adjudicator: any SequenceAdjudicator)
        -> ConsensusEstimate {
        var pages: Set<Int> = []
        for r in results.values { for p in r.pages { pages.insert(p.page) } }

        var items: [ItemConsensus] = []
        var agreement: [String: [String: Double]] = [:]
        var overall: [String: [Double]] = [:]
        for page in pages.sorted() {
            var sequences: [String: [String]] = [:]
            for (engine, result) in results {
                guard let pageResult = result.pages.first(where: { $0.page == page }) else { continue }
                sequences[engine] = ConfusionNetworkBuilder.tokenize(pageResult.text)
            }
            guard sequences.count >= 2 else { continue }
            let estimate = adjudicator.adjudicate(
                network: ConfusionNetworkBuilder.build(page: page, sequences: sequences))
            items.append(contentsOf: estimate.items)
            // Last page wins for the diagnostic matrices; per-page values are
            // averaged for competence so a long document is not dominated by
            // its final page.
            agreement = estimate.agreement
            for (engine, value) in estimate.diagnostics.overallCompetence ?? [:] {
                overall[engine, default: []].append(value)
            }
        }
        return ConsensusEstimate(
            adjudicator: type(of: adjudicator).id,
            items: items,
            agreement: agreement,
            diagnostics: AdjudicatorDiagnostics(
                overallCompetence: overall.mapValues { $0.reduce(0, +) / Double($0.count) },
                competence: nil, iterations: nil, converged: nil, confusion: nil))
    }

    /// Page-wise extract + align across engines, then estimate.
    /// Page-wise extract + align across engines, then estimate.
    ///
    /// The adjudicator is injected (#17). It defaults to Dawid-Skene-lite so
    /// every pre-existing call site keeps its exact behaviour; an unknown id
    /// must be rejected by the caller rather than silently defaulting here —
    /// running a different model under the requested one's estimand name is
    /// precisely the mislabelling this design exists to prevent.
    public static func adjudicate(results: [String: OCRResult],
                                  adjudicator: any ConsensusAdjudicator
                                      = DawidSkeneLiteAdjudicator()) -> ConsensusEstimate {
        var pages: Set<Int> = []
        for r in results.values { for p in r.pages { pages.insert(p.page) } }

        return adjudicator.adjudicate(items: alignedItems(results: results))
    }

    /// Page-wise extract + align, shared by adjudication and the #38
    /// co-answer gate (which must see the items BEFORE any estimator runs).
    public static func alignedItems(results: [String: OCRResult]) -> [AlignedItem] {
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
        return allItems
    }

    // MARK: - #38 co-answer gate

    /// Share of aligned items with ≥2 non-empty responses — computed on
    /// AlignedItems so the gate can run before the estimator (the report's
    /// own figure is computed later from verdicts; same formula).
    public static func coAnswerShare(of items: [AlignedItem]) -> Double {
        guard !items.isEmpty else { return 0 }
        let coAnswered = items.filter { item in
            item.responses.values.filter { !$0.normalized.isEmpty }.count >= 2
        }.count
        return Double(coAnswered) / Double(items.count)
    }

    /// Response-count distribution ("1" → 1328 …): how many items got how
    /// many engine responses — the structural picture behind a low share.
    public static func responseCounts(of items: [AlignedItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            let n = item.responses.values.filter { !$0.normalized.isEmpty }.count
            counts["\(n)", default: 0] += 1
        }
        return counts
    }

    /// Default 0.2 — a deliberately LOW bar that only refuses plainly
    /// degenerate runs (#38 measured 0.0867); uncalibrated single-sample
    /// induction, env-overridable, evidence-pending (same discipline as the
    /// triage thresholds). Garbage values fall back to the default.
    public static func minCoAnswerThreshold(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        guard let raw = env["BESTOCR_CONSENSUS_MIN_COANSWER"], let v = Double(raw),
              v > 0, v <= 1 else { return 0.2 }
        return v
    }

    /// nil = proceed; a String = refuse with this reason. Competence computed
    /// from near-zero co-answers is not a weak estimate of engine quality —
    /// it is an estimate of something else wearing the same shape (#38).
    public static func coAnswerGate(items: [AlignedItem], threshold: Double) -> String? {
        let share = coAnswerShare(of: items)
        guard share < threshold else { return nil }
        return "co_answer_share \(String(format: "%.4f", share)) below threshold "
            + "\(String(format: "%.2f", threshold)) — alignment mostly never happened; "
            + "competence would measure segmentation mismatch, not engine quality"
    }

    // MARK: - #39 single-consensus gate

    /// The CCT validity condition of the pooling estimators themselves:
    /// the agreement structure must be consistent with ONE latent answer key
    /// (dominant first eigenvalue + no zero first-factor loadings) or
    /// per-engine competence is an estimate of a quantity that does not
    /// exist for the run. Ordering is fixed: the #38 co-answer gate runs
    /// first (an alignment that barely happened cannot be tested for
    /// partition structure), then this, then the estimator.
    ///
    /// nil refusalReason = proceed; the check outcome (passed / untestable)
    /// is still recorded so "could not test" never renders as "tested and
    /// held". Non-pooling adjudicators (majority, rover) get (nil, nil) —
    /// no competence claim, no assumption to guard (issue Non-Goal).
    public static func singleConsensusGate(
        items: [AlignedItem], engines: [String], adjudicatorID: String
    ) -> (refusalReason: String?, check: SingleConsensusCheck?) {
        guard AdjudicatorRegistry.poolsRaters(adjudicatorID) else {
            return (nil, nil)
        }
        let agreement = ConsensusEstimator.agreementMatrix(items: items, engines: engines)
        let minRatio = ConsensusValidity.minEigenRatio()
        let result = ConsensusValidity.singleConsensusCheck(
            agreement: agreement, engines: engines, minRatio: minRatio)
        let check = SingleConsensusCheck(verdict: result.verdict, excluded: result.excluded,
                                         minRatio: minRatio,
                                         ratioUnbounded: result.ratioUnbounded)
        if case .failed(let reason, _) = result.verdict {
            return (reason, check)
        }
        return (nil, check)
    }

    /// "One line, one fact": collapse every newline carrier (LF, CR, CRLF,
    /// NEL, FF, U+2028/2029) so no interpolated value can write its own
    /// output line. Renderers apply this to every user- or subprocess-
    /// influenced string (skipped ids, adapter stderr reasons, artifact
    /// paths) — an embedded newline in any of them could forge an
    /// authoritative-looking line such as `single-consensus: passed`
    /// (R1 security M1; R2 NEW-1/2).
    /// Iterates by `Character` so CRLF — ONE grapheme in Swift — becomes
    /// ONE ⏎ (R3: `components(separatedBy: .newlines)` split it into two
    /// separators, contradicting the one-carrier contract; CharacterSet
    /// membership is scalar-wise, `Character.isNewline` is grapheme-wise).
    public static func oneLine(_ s: String) -> String {
        String(s.map { $0.isNewline ? "⏎" : $0 })
    }

    // MARK: - Outputs

    /// Writes `<stem>.consensus.md` (transcript; low-consensus items prefixed
    /// with `⚠`) and `<stem>.consensus.json` (report). MVP limitation,
    /// documented: table structure is not reconstructed — cells appear as
    /// individual lines; the report is the primary artifact for review.
    public static func writeOutputs(estimate: ConsensusEstimate, engines: [String],
                                    skipped: [String: String], inputPath: String,
                                    outDir: URL,
                                    singleConsensus: SingleConsensusCheck? = nil)
        throws -> (markdown: URL, report: URL) {
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

        let report = ConsensusReport(estimate: estimate, engines: engines, skipped: skipped,
                                     singleConsensus: singleConsensus)
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
                               runLog: RunLog,
                               adjudicatorID: String = DawidSkeneLiteAdjudicator.id)
        async throws -> ConsensusRunSummary {
        // Unknown id is a hard error, never a silent fallback: running a
        // different model under the requested one's estimand name is exactly
        // the mislabelling #17 exists to prevent.
        guard AdjudicatorRegistry.isKnown(adjudicatorID) else {
            throw OCREngineError(engine: "consensus",
                                 message: "unknown adjudicator '\(adjudicatorID)' — available: "
                                     + AdjudicatorRegistry.allIDs.joined(separator: ", "))
        }
        // nil only for sequence adjudicators, which take the branch below.
        var adjudicator = AdjudicatorRegistry.make(adjudicatorID) ?? AdjudicatorRegistry.default
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
            let trail = skipped.map { oneLine("\($0.key): \($0.value)") }.sorted().joined(separator: "; ")
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
            let trail = skipped.map { oneLine("\($0.key): \($0.value)") }.sorted().joined(separator: "; ")
            throw OCREngineError(engine: "consensus",
                                 message: "fewer than 2 engines produced output — \(trail)")
        }

        // Overwrite is surfaced, never silent (#13 F15c) — measured BEFORE
        // any writer runs, because the refusal paths replace the same two
        // artifacts and must report it honestly too, not just the success
        // path (R1 security M2: a previous valid run's transcript silently
        // became two lines of refusal while the tool claimed otherwise).
        let stem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let overwrote = ["md", "json"].contains { ext in
            FileManager.default.fileExists(
                atPath: outDir.appendingPathComponent("\(stem).consensus.\(ext)").path)
        }
        let estimate: ConsensusEstimate
        var singleConsensus: SingleConsensusCheck?
        if AdjudicatorRegistry.isSequenceAdjudicator(adjudicatorID) {
            // Phase 5: ROVER consumes a confusion network built from raw page
            // text, not aligned items — the two inputs are genuinely different.
            estimate = adjudicateSequence(results: results, adjudicator: ROVERAdjudicator())
        } else {
            // Phase 3: the prior-weighted model needs a prior built from
            // measured rows for the engines that actually ran.
            if adjudicatorID == PriorWeightedAdjudicator.id {
                let store = (try? EvidenceStore.load(from: EvidenceStore.defaultURL()))
                    ?? EvidenceStore(rows: [])
                adjudicator = PriorWeightedAdjudicator.fromEvidence(
                    store, engineIDs: results.keys.sorted())
            }
            // #38 co-answer gate — BEFORE any estimator: competence computed
            // from near-zero co-answers measures segmentation mismatch, not
            // engine quality. A refusal is a measurement outcome (exit 0,
            // full alignment diagnostics), not a tool error. Pooling
            // adjudicators only; ROVER's confusion-network alignment is a
            // different model with its own co-answer semantics (out of scope).
            let items = alignedItems(results: results)
            if let reason = coAnswerGate(items: items,
                                         threshold: minCoAnswerThreshold()) {
                // The single-consensus check did not run for a co-answer
                // refusal — nil check, honestly (order: #38 before #39).
                return try refusedRun(reason: reason, check: nil, items: items,
                                      engines: results.keys.sorted(),
                                      skipped: skipped, adjudicatorID: adjudicatorID,
                                      inputPath: inputPath, outDir: outDir,
                                      overwrote: overwrote)
            }
            // #39 single-consensus gate (see `singleConsensusGate` doc for
            // the ordering contract): failed → refuse with the check
            // recorded; passed / untestable → proceed with it disclosed.
            let gate = singleConsensusGate(items: items,
                                           engines: results.keys.sorted(),
                                           adjudicatorID: adjudicatorID)
            singleConsensus = gate.check
            if let reason = gate.refusalReason {
                return try refusedRun(reason: reason, check: gate.check, items: items,
                                      engines: results.keys.sorted(),
                                      skipped: skipped, adjudicatorID: adjudicatorID,
                                      inputPath: inputPath, outDir: outDir,
                                      overwrote: overwrote)
            }
            estimate = adjudicator.adjudicate(items: items)
        }
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
        let outputs = try writeOutputs(estimate: estimate,
                                       engines: results.keys.sorted(),
                                       skipped: skipped,
                                       inputPath: inputPath, outDir: outDir,
                                       singleConsensus: singleConsensus)

        // Provenance (#12): one explicit composite entry — the ensemble is
        // the unit under measurement. Promotion to evidence rows stays behind
        // the manual `evidence ingest <run-id>` gate.
        let share = estimate.items.isEmpty ? 0
            : Double(estimate.items.filter(\.lowConsensus).count) / Double(estimate.items.count)
        let entry = RunLogEntry(
            consensusOf: results, input: inputPath, output: outputs.markdown.path,
            quality: .init(estimand: Estimand.consensus(estimate.adjudicator, "low_consensus_share"),
                           value: share,
                           reference: "engines=\(results.keys.sorted().joined(separator: "+"))"
                               + ";adjudicator=\(estimate.adjudicator)"
                               + ";converged=\(estimate.diagnostics.converged.map(String.init) ?? "n/a")"))
        try runLog.append(entry)

        return ConsensusRunSummary(outputMarkdown: outputs.markdown,
                                   outputReport: outputs.report,
                                   engines: results.keys.sorted(),
                                   skipped: skipped,
                                   estimate: estimate,
                                   runID: entry.id,
                                   overwrote: overwrote,
                                   singleConsensus: singleConsensus)
    }

    /// Shared refusal writer for the #38 co-answer gate and the #39
    /// single-consensus gate: refused markdown + report, no runlog quality
    /// entry (runID "" — structurally un-ingestable), returned as a summary
    /// with exit-0 semantics (a refusal is a measurement outcome, not a
    /// tool error).
    private static func refusedRun(reason: String, check: SingleConsensusCheck?,
                                   items: [AlignedItem], engines: [String],
                                   skipped: [String: String], adjudicatorID: String,
                                   inputPath: String, outDir: URL,
                                   overwrote: Bool)
        throws -> ConsensusRunSummary {
        let report = ConsensusReport.refused(items: items, engines: engines,
                                             skipped: skipped,
                                             adjudicator: adjudicatorID,
                                             reason: reason,
                                             singleConsensus: check)
        try FileManager.default.createDirectory(at: outDir,
                                                withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let mdURL = outDir.appendingPathComponent("\(stem).consensus.md")
        try ("# Consensus refused\n\n\(reason)\n\nSee \(stem).consensus.json "
             + "for the alignment diagnostics (response-count distribution, "
             + "agreement matrix). No competence was estimated.\n")
            .write(to: mdURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonURL = outDir.appendingPathComponent("\(stem).consensus.json")
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        return ConsensusRunSummary(
            outputMarkdown: mdURL, outputReport: jsonURL, engines: engines,
            skipped: skipped,
            estimate: ConsensusEstimate(adjudicator: adjudicatorID, items: [],
                                        agreement: report.agreement,
                                        diagnostics: AdjudicatorDiagnostics()),
            runID: "", overwrote: overwrote,
            refused: true, refusalReason: reason,
            singleConsensus: check)
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
    /// renderings (v1 published normalized text). 3 = the adjudicator is named
    /// and its model-specific fields are optional, so "this model has no such
    /// notion" is representable rather than being flattened to a zero (#17).
    /// Legacy files decode as 1/2 with `adjudicator` defaulting to ds-lite.
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    /// Which adjudicator produced this report. Absent in schema < 3, where
    /// ds-lite was the only adjudicator that existed.
    let adjudicator: String
    let engines: [String]
    let skipped: [String: String]
    let itemCount: Int
    /// `nil` for non-iterative adjudicators (naive majority).
    let iterations: Int?
    /// `nil` when convergence is undefined for the adjudicator.
    let converged: Bool?
    /// Share of items with ≥2 responses — the honest coverage number: how
    /// much of the transcript is actually corroborated vs single-engine.
    let coAnswerShare: Double
    /// Engines that produced output but zero alignable items — they appear
    /// in `engines` yet are absent from the competence maps; called out
    /// instead of silently missing.
    let enginesWithoutAlignedItems: [String]
    /// #38: the run refused to estimate (co-answer gate). refused reports
    /// keep alignment diagnostics and carry NO competence — the two states
    /// must never look alike.
    let refused: Bool
    let refusalReason: String?
    /// Response-count distribution over aligned items ("1" → solo items …).
    let responseCounts: [String: Int]?
    /// Per-engine informative-item counts behind overallCompetence (#38):
    /// n = 0 → the figure is the bare Laplace prior, not a measurement.
    let informativeItems: [String: Int]?
    /// #39: single-consensus validity check outcome. nil = the check did not
    /// run (pre-#39 report, majority, rover, or a co-answer refusal that
    /// never got that far) — absence is never a verdict.
    let singleConsensus: SingleConsensusCheck?
    /// `nil` when the adjudicator has no competence notion — distinct from an
    /// empty map, which means it has one and nothing qualified (#17 §4.2).
    let overallCompetence: [String: Double]?
    let competenceByKind: [String: [String: Double]]?
    let agreement: [String: [String: Double]]
    let lowConsensus: [LowConsensusItem]

    enum CodingKeys: String, CodingKey {
        case engines, skipped, iterations, converged, agreement
        case schemaVersion = "schema_version"
        case adjudicator
        case itemCount = "item_count"
        case coAnswerShare = "co_answer_share"
        case enginesWithoutAlignedItems = "engines_without_aligned_items"
        case overallCompetence = "overall_competence"
        case competenceByKind = "competence_by_kind"
        case lowConsensus = "low_consensus"
        case refused
        case refusalReason = "refusal_reason"
        case responseCounts = "response_counts"
        case informativeItems = "informative_items"
        case singleConsensus = "single_consensus"
    }

    /// Custom decode: fields added after the first release default instead
    /// of failing on old report files (`converged` → false, coverage → 0/[]).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.engines = try c.decode([String].self, forKey: .engines)
        self.skipped = try c.decode([String: String].self, forKey: .skipped)
        self.itemCount = try c.decode(Int.self, forKey: .itemCount)
        // Reports written before adjudicators were pluggable were all
        // Dawid-Skene-lite — the only adjudicator that existed.
        self.adjudicator = try c.decodeIfPresent(String.self, forKey: .adjudicator) ?? "ds-lite"
        self.iterations = try c.decodeIfPresent(Int.self, forKey: .iterations)
        self.converged = try c.decodeIfPresent(Bool.self, forKey: .converged)
        self.coAnswerShare = try c.decodeIfPresent(Double.self, forKey: .coAnswerShare) ?? 0
        self.enginesWithoutAlignedItems =
            try c.decodeIfPresent([String].self, forKey: .enginesWithoutAlignedItems) ?? []
        self.refused = try c.decodeIfPresent(Bool.self, forKey: .refused) ?? false
        self.refusalReason = try c.decodeIfPresent(String.self, forKey: .refusalReason)
        self.responseCounts = try c.decodeIfPresent([String: Int].self, forKey: .responseCounts)
        self.informativeItems = try c.decodeIfPresent([String: Int].self, forKey: .informativeItems)
        self.singleConsensus = try c.decodeIfPresent(SingleConsensusCheck.self,
                                                     forKey: .singleConsensus)
        self.overallCompetence = try c.decodeIfPresent([String: Double].self, forKey: .overallCompetence)
        self.competenceByKind = try c.decodeIfPresent([String: [String: Double]].self,
                                                      forKey: .competenceByKind)
        self.agreement = try c.decode([String: [String: Double]].self, forKey: .agreement)
        self.lowConsensus = try c.decode([LowConsensusItem].self, forKey: .lowConsensus)
    }

    init(estimate: ConsensusEstimate, engines: [String], skipped: [String: String],
         singleConsensus: SingleConsensusCheck? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.engines = engines
        self.skipped = skipped
        self.refused = false
        self.refusalReason = nil
        self.singleConsensus = singleConsensus
        self.responseCounts = Dictionary(grouping: estimate.items) { item in
            item.responses.values.filter { !$0.isEmpty }.count
        }.reduce(into: [:]) { $0["\($1.key)"] = $1.value.count }
        self.informativeItems = estimate.diagnostics.informativeItems
        self.itemCount = estimate.items.count
        self.adjudicator = estimate.adjudicator
        self.iterations = estimate.diagnostics.iterations
        self.converged = estimate.diagnostics.converged
        self.coAnswerShare = estimate.items.isEmpty ? 0
            : Double(estimate.items.filter { item in
                item.responses.values.filter { !$0.isEmpty }.count >= 2
              }.count) / Double(estimate.items.count)
        self.enginesWithoutAlignedItems = engines.filter { engine in
            !estimate.items.contains { ($0.responses[engine]?.isEmpty == false) }
        }.sorted()
        // nil (not [:]) when the adjudicator has no competence notion — a
        // majority report must not read like a degenerate Dawid-Skene one (#17).
        self.overallCompetence = estimate.diagnostics.overallCompetence
        self.competenceByKind = estimate.diagnostics.competence.map { byEngine in
            byEngine.mapValues { kinds in
                Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.rawValue, $0.value) })
            }
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

    /// #38 refused shape: alignment diagnostics preserved, competence absent —
    /// no estimator ran, so iterations/converged/competence are nil, never 0.
    static func refused(items: [AlignedItem], engines: [String],
                        skipped: [String: String], adjudicator: String,
                        reason: String,
                        singleConsensus: SingleConsensusCheck? = nil) -> ConsensusReport {
        ConsensusReport(refusedWith: reason, items: items, engines: engines,
                        skipped: skipped, adjudicator: adjudicator,
                        singleConsensus: singleConsensus)
    }

    private init(refusedWith reason: String, items: [AlignedItem],
                 engines: [String], skipped: [String: String], adjudicator: String,
                 singleConsensus: SingleConsensusCheck?) {
        self.schemaVersion = Self.currentSchemaVersion
        self.engines = engines
        self.skipped = skipped
        self.adjudicator = adjudicator
        self.refused = true
        self.refusalReason = reason
        self.singleConsensus = singleConsensus
        self.itemCount = items.count
        self.iterations = nil
        self.converged = nil
        self.coAnswerShare = ConsensusPipeline.coAnswerShare(of: items)
        self.responseCounts = ConsensusPipeline.responseCounts(of: items)
        self.informativeItems = nil
        self.enginesWithoutAlignedItems = engines.filter { engine in
            !items.contains { ($0.responses[engine]?.normalized.isEmpty == false) }
        }.sorted()
        self.overallCompetence = nil
        self.competenceByKind = nil
        self.agreement = ConsensusEstimator.agreementMatrix(items: items, engines: engines)
        self.lowConsensus = []
    }
}
