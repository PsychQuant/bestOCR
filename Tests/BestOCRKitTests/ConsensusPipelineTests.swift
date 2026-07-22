import Foundation
import Testing
@testable import BestOCRKit

/// ConsensusPipeline (#11): pure adjudication core + output writer.
struct ConsensusPipelineTests {

    private func result(_ engine: String, _ text: String) -> OCRResult {
        OCRResult(engineID: engine,
                  pages: [PageResult(page: 1, text: text, seconds: 0.1,
                                     thermalState: "nominal", degenerateFlagged: false)],
                  condition: ConditionTuple(model: engine, quant: "n/a", dpi: 150,
                                            docType: "test", platform: "test",
                                            hardware: "test", instrument: "test"))
    }

    @Test func adjudicateRecoversConsensusAcrossEngines() {
        let good = "line one\nline two\nline three"
        let bad = "line one\nline TWO-GARBLED\nline three"
        let estimate = ConsensusPipeline.adjudicate(results: [
            "A": result("A", good),
            "B": result("B", bad),
            "C": result("C", good),
        ])
        #expect(estimate.items.count == 3)
        let texts = estimate.items.map(\.consensusText)
        #expect(texts == ["line one", "line two", "line three"])
        let a = estimate.overallCompetence["A"] ?? 0
        let b = estimate.overallCompetence["B"] ?? 0
        #expect(a > b, "engine with the garbled line must score lower")
    }

    @Test func consensusRunLogEntryIsExplicitComposite() {
        // #12: the ensemble is the unit under measurement — never crammed
        // into a single member engine's fields (that would poison the
        // evidence condition semantics).
        let entry = RunLogEntry(
            consensusOf: ["B": result("B", "x\ny"), "A": result("A", "x\ny")],
            input: "/tmp/in.pdf", output: "/tmp/out.md",
            quality: .init(estimand: "consensus.low_consensus_share@v1", value: 0.25,
                           reference: "engines=A+B;converged=true"))
        #expect(entry.engineID == "consensus")
        #expect(entry.condition.model == "A+B")
        #expect(entry.condition.platform == "consensus")
        #expect(entry.condition.quant == "n/a")
        #expect(entry.pages.count == 1)
        #expect(abs(entry.pages[0].seconds - 0.2) < 1e-9,
                "page seconds are the ensemble TOTAL across engines")
        #expect(entry.quality?.estimand == "consensus.low_consensus_share@v1")
    }

    @Test func consensusEntryIngestsAsEnsembleEstimands() {
        // #12: distinct estimand strings keep ensemble numbers out of any
        // single-engine ranking (schema.md hard rule — never mixed), and the
        // quality caveat must speak consensus, not compare's cloud wording.
        let entry = RunLogEntry(
            consensusOf: ["A": result("A", "x"), "B": result("B", "x")],
            input: "/tmp/in.pdf", output: "/tmp/out.md",
            quality: .init(estimand: "consensus.low_consensus_share@v1", value: 0.1,
                           reference: "engines=A+B;converged=true"))
        let rows = EvidenceIngest.rows(from: entry)
        #expect(rows.count == 2)
        #expect(rows[0].estimand == "speed.ensemble_ms_per_page@v1")
        #expect(rows[0].caveat?.contains("ensemble") == true)
        #expect(rows[1].estimand == "consensus.low_consensus_share@v1")
        #expect(rows[1].caveat?.contains("not ground truth") == true)
        #expect(rows[1].caveat?.contains("cloud") != true,
                "consensus quality must not inherit compare's cloud caveat")
    }

    @Test func executeWritesConsensusRunLogEntry() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-runlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")!
        let img = tmp.appendingPathComponent("fixture.png")
        try png.write(to: img)
        let runLog = RunLog(fileURL: tmp.appendingPathComponent("runlog.jsonl"))
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello"),
            StubEngine(id: "B", availability: .available, text: "hello"),
        ])
        let summary = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B"], dpi: 150, pageSpec: "",
            languages: [], docType: "test", outDir: tmp.appendingPathComponent("out"),
            registry: registry, runLog: runLog)
        #expect(!summary.runID.isEmpty)
        let log = try String(contentsOf: runLog.fileURL, encoding: .utf8)
        #expect(log.contains("\"engineID\":\"consensus\""))
        #expect(log.contains(summary.runID))
    }

    @Test func writeOutputsProducesTranscriptAndReport() throws {
        // Fixture note (r2): a same-position disagreement now gets outvoted
        // via equal-gap pairing (correct — not low consensus). To exercise
        // the low_consensus report path we need a genuinely uncorroborated
        // item: an extra hallucinated line only engine C produced.
        let estimate = ConsensusPipeline.adjudicate(results: [
            "A": result("A", "hello\nworld"),
            "B": result("B", "hello\nworld"),
            "C": result("C", "hello\nworld\nEXTRA-HALLUCINATION"),
        ])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-test-\(UUID().uuidString)")
        let out = try ConsensusPipeline.writeOutputs(
            estimate: estimate, engines: ["A", "B", "C"], skipped: [:],
            inputPath: "/tmp/sample.pdf", outDir: tmp)

        let md = try String(contentsOf: out.markdown, encoding: .utf8)
        #expect(md.contains("hello"))

        let data = try Data(contentsOf: out.report)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["engines"] as? [String] == ["A", "B", "C"])
        #expect(json?["overall_competence"] != nil)
        let low = json?["low_consensus"] as? [[String: Any]]
        #expect((low?.count ?? 0) >= 1, "the A/B-vs-C fork must surface in low_consensus")
    }
}
