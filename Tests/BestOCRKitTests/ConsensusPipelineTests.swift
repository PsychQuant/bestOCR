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
