import Testing
@testable import BestOCRKit

struct RecommenderTests {
    static func mathEngine(_ id: String) -> StubEngine {
        StubEngine(id: id, availability: .available, text: "x",
                   outputLevel: .mathMarkdown)
    }

    static func row(model: String, tier: String, estimand: String, value: Double,
                    docType: String = "math_pdf") -> EvidenceRow {
        EvidenceRow(estimand: estimand, value: value,
                    condition: ConditionTuple(model: model, quant: "q8_0", dpi: 100,
                                              docType: docType, platform: "ollama",
                                              hardware: "test", instrument: "test"),
                    tier: tier, source: "test:\(model):\(tier)")
    }

    let registry = EngineRegistry(engines: [
        RecommenderTests.mathEngine("vlm.glm-ocr"),
        RecommenderTests.mathEngine("vlm.ovisocr2"),
        StubEngine(id: "vision", availability: .available, text: "x", outputLevel: .plainText),
    ])

    @Test func noEvidenceYieldsHonestPendingWithCandidates() {
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", needsMath: true),
            registry: registry, evidence: EvidenceStore(rows: []))
        #expect(answer.mode == .evidencePending)
        // Capability filter: needsMath excludes the plain-text engine.
        #expect(answer.entries.map(\.engineID) == ["vlm.glm-ocr", "vlm.ovisocr2"])
        #expect(answer.entries.allSatisfy { $0.note.contains("unverified") })
        #expect(answer.citations.isEmpty)
    }

    @Test func ranksWithinSingleTierAndCites() {
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T2", estimand: "quality.word_recall", value: 0.98),
            Self.row(model: "ovisocr2", tier: "T2", estimand: "quality.word_recall", value: 0.95),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .quality, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.mode == .ranked(tier: "T2"))
        #expect(answer.entries.first?.engineID == "vlm.glm-ocr")   // higher recall first
        #expect(answer.citations.contains("test:glm-ocr:T2"))
    }

    @Test func neverMixesTiersInOneRanking() {
        // glm has T1; ovis has only T2 → ranking is T1-only, ovis is noted, not ranked.
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T1", estimand: "quality.word_recall", value: 0.97),
            Self.row(model: "ovisocr2", tier: "T2", estimand: "quality.word_recall", value: 0.99),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .quality, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.mode == .ranked(tier: "T1"))
        let ranked = answer.entries.filter { !$0.note.contains("not rankable") && !$0.note.contains("unverified") }
        #expect(ranked.map(\.engineID) == ["vlm.glm-ocr"])
        let ovis = answer.entries.first { $0.engineID == "vlm.ovisocr2" }
        #expect(ovis?.note.contains("T2") == true)
        #expect(ovis?.note.contains("not rankable") == true)
    }

    @Test func t3RowsAreNeverRanked() {
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T3", estimand: "quality.word_recall", value: 0.99),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .quality, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.mode == .evidencePending)   // T3 alone never produces a ranking
    }

    @Test func speedPriorityRanksAscending() {
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T2", estimand: "speed.ms_per_page", value: 2000),
            Self.row(model: "ovisocr2", tier: "T2", estimand: "speed.ms_per_page", value: 1500),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .speed, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.entries.first?.engineID == "vlm.ovisocr2")   // faster first
    }

    @Test func cloudReferenceEnginesAreNeverRankedNorListed() {
        // Spec §6.1.3: cloud is reference-only — excluded even with matching rows.
        let cloudRegistry = EngineRegistry(engines: [
            RecommenderTests.mathEngine("vlm.glm-ocr"),
            CloudReferenceEngine(provider: .claude),
        ])
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T2", estimand: "quality.word_recall", value: 0.98),
            Self.row(model: "claude-opus-4-8", tier: "T2", estimand: "quality.word_recall", value: 0.99),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .quality),
            registry: cloudRegistry, evidence: evidence)
        #expect(!answer.entries.contains { $0.engineID.hasPrefix("cloud.") })
        #expect(answer.entries.map(\.engineID) == ["vlm.glm-ocr"])
    }

    @Test func modelToEngineMatchingHandlesAnovaTags() {
        // Evidence rows say "glm-ocr"; live VLM engines carry "-anova:q8_0" tags.
        #expect(Recommender.baseModel("glm-ocr-anova:q8_0") == "glm-ocr")
        #expect(Recommender.baseModel("glm-ocr") == "glm-ocr")
        #expect(Recommender.baseModel("tesseract") == "tesseract")
    }
}
