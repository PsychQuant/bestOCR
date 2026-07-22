import Foundation

/// Result of one consensus run (#11).
public struct ConsensusRunSummary: Sendable {
    public let outputMarkdown: URL
    public let outputReport: URL
    public let engines: [String]
    public let skipped: [String: String]   // engineID → reason
    public let estimate: ConsensusEstimate
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
            for (engine, result) in results {
                guard let pageResult = result.pages.first(where: { $0.page == page }) else { continue }
                extractions[engine] = ItemExtractor.extract(page: page, text: pageResult.text)
            }
            allItems.append(contentsOf: ConsensusAlignment.align(page: page, extractions: extractions))
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
        try encoder.encode(report).write(to: jsonURL)
        return (mdURL, jsonURL)
    }

    // MARK: - Engine-running shell

    /// Runs the requested engines over one normalized input. Requires at
    /// least two available engines — consensus over one informant is not
    /// consensus (spec: CCT needs corroboration; ≥3 recommended, ≥2 hard floor).
    public static func execute(inputPath: String, engineIDs: [String], dpi: Double,
                               pageSpec: String, languages: [String], docType: String,
                               outDir: URL, registry: EngineRegistry) async throws -> ConsensusRunSummary {
        var skipped: [String: String] = [:]
        var candidates: [any OCREngine] = []
        for id in engineIDs {
            guard let engine = registry.engine(id: id) else {
                skipped[id] = "unknown engine id"
                continue
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
        let outputs = try writeOutputs(estimate: estimate,
                                       engines: results.keys.sorted(),
                                       skipped: skipped,
                                       inputPath: inputPath, outDir: outDir)
        return ConsensusRunSummary(outputMarkdown: outputs.markdown,
                                   outputReport: outputs.report,
                                   engines: results.keys.sorted(),
                                   skipped: skipped,
                                   estimate: estimate)
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

    let engines: [String]
    let skipped: [String: String]
    let itemCount: Int
    let iterations: Int
    let overallCompetence: [String: Double]
    let competenceByKind: [String: [String: Double]]
    let agreement: [String: [String: Double]]
    let lowConsensus: [LowConsensusItem]

    enum CodingKeys: String, CodingKey {
        case engines, skipped, iterations, agreement
        case itemCount = "item_count"
        case overallCompetence = "overall_competence"
        case competenceByKind = "competence_by_kind"
        case lowConsensus = "low_consensus"
    }

    init(estimate: ConsensusEstimate, engines: [String], skipped: [String: String]) {
        self.engines = engines
        self.skipped = skipped
        self.itemCount = estimate.items.count
        self.iterations = estimate.iterations
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
