import Testing
@testable import BestOCRKit

struct AutoRouterTests {
    func mathEngine(_ id: String) -> StubEngine {
        StubEngine(id: id, availability: .available, text: "x", outputLevel: .mathMarkdown)
    }

    func row(model: String, value: Double) -> EvidenceRow {
        EvidenceRow(estimand: "quality.word_recall", value: value,
                    condition: ConditionTuple(model: model, quant: "q8_0", dpi: 100,
                                              docType: "math_pdf", platform: "ollama",
                                              hardware: "test", instrument: "test"),
                    tier: "T2", source: "test:\(model)")
    }

    @Test func rankedEnginesLeadUnverifiedFollowCloudAbsent() {
        let registry = EngineRegistry(engines: [
            mathEngine("vlm.glm-ocr"),
            mathEngine("vlm.ovisocr2"),
            CloudReferenceEngine(provider: .claude),
        ])
        let evidence = EvidenceStore(rows: [row(model: "ovisocr2", value: 0.99)])
        let selection = AutoRouter.candidates(
            docType: "math_pdf", languages: [], priority: .quality, needsMath: true,
            registry: registry, evidence: evidence)
        #expect(selection.candidateIDs == ["vlm.ovisocr2", "vlm.glm-ocr"])   // ranked first
        #expect(selection.mode == .ranked(tier: "T2"))
        #expect(!selection.candidateIDs.contains { $0.hasPrefix("cloud.") })
    }

    @Test func noEvidenceFallsBackToCapabilityOrder() {
        let registry = EngineRegistry(engines: [
            mathEngine("vlm.glm-ocr"), mathEngine("vlm.ovisocr2"),
        ])
        let selection = AutoRouter.candidates(
            docType: "math_pdf", languages: [], priority: .balanced, needsMath: true,
            registry: registry, evidence: EvidenceStore(rows: []))
        #expect(selection.mode == .evidencePending)
        #expect(selection.candidateIDs == ["vlm.glm-ocr", "vlm.ovisocr2"])   // registry order
    }

    @Test func capabilityFilterCanEmptyTheSelection() {
        let registry = EngineRegistry(engines: [
            StubEngine(id: "vision", availability: .available, text: "x"),   // plainText
        ])
        let selection = AutoRouter.candidates(
            docType: "math_pdf", languages: [], priority: .quality, needsMath: true,
            registry: registry, evidence: EvidenceStore(rows: []))
        #expect(selection.candidateIDs.isEmpty)
    }
}
