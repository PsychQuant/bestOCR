import Foundation
import Testing
@testable import BestOCRKit

/// Phase 0b of the document-assembly spec (§5.3): `evidence/schema.md` states
/// versioned estimand names, and pre-existing unversioned names are *read as*
/// `@v1` so no committed row is rewritten. A doc-only fix would be a claim the
/// code does not honour — these tests are what makes the compat line true.
struct EstimandTests {
    @Test func unversionedNamesCanonicalizeToV1() {
        #expect(Estimand.canonical("speed.ms_per_page") == "speed.ms_per_page@v1")
        #expect(Estimand.canonical("quality.word_recall") == "quality.word_recall@v1")
    }

    @Test func alreadyVersionedNamesAreLeftAlone() {
        #expect(Estimand.canonical("quality.token_recall_vs_cloud@v1")
                == "quality.token_recall_vs_cloud@v1")
        #expect(Estimand.canonical("speed.ensemble_ms_per_page@v1")
                == "speed.ensemble_ms_per_page@v1")
    }

    /// A version bump means a different formula. Canonicalization must NEVER
    /// make v1 and v2 look like the same estimand (schema hard rule 2).
    @Test func differentVersionsNeverCollapse() {
        #expect(Estimand.canonical("speed.ms_per_page")
                != Estimand.canonical("speed.ms_per_page@v2"))
    }

    @Test func newAssemblyEstimandsAreNamedAndVersioned() {
        #expect(Estimand.readingOrderTau == "quality.reading_order_tau@v1")
        #expect(Estimand.tableStructureF1 == "quality.table_structure_f1@v1")
        #expect(Estimand.canonical(Estimand.readingOrderTau) == Estimand.readingOrderTau)
    }

    /// The compat guarantee that actually matters: a row ingested before the
    /// rename and a row ingested after it describe the same estimand, so they
    /// rank in ONE ranking instead of silently splitting into two.
    @Test func legacyAndVersionedRowsRankTogether() {
        let registry = EngineRegistry(engines: [
            StubEngine(id: "vlm.glm-ocr", availability: .available, text: "x"),
            StubEngine(id: "vlm.ovisocr2", availability: .available, text: "x"),
        ])
        func row(_ model: String, _ estimand: String, _ value: Double) -> EvidenceRow {
            EvidenceRow(estimand: estimand, value: value,
                        condition: ConditionTuple(model: model, quant: "q8_0", dpi: 100,
                                                  docType: "scanned_doc", platform: "ollama",
                                                  hardware: "test", instrument: "test"),
                        tier: "T2", source: "test:\(model)")
        }
        let evidence = EvidenceStore(rows: [
            row("glm-ocr", "speed.ms_per_page", 3000),          // legacy form
            row("ovisocr2", "speed.ms_per_page@v1", 1500),      // post-rename form
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "scanned_doc", priority: .speed),
            registry: registry, evidence: evidence)
        #expect(answer.mode == .ranked(tier: "T2"))
        // Both rows carried the ranking, faster first — not one ranked and one
        // reported "unverified".
        #expect(answer.entries.map(\.engineID) == ["vlm.ovisocr2", "vlm.glm-ocr"])
        #expect(answer.citations.count == 2)
    }
}
