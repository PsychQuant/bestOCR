import Testing
@testable import BestOCRKit

/// #29 — the surya generation decision, made first-class instead of implicit.
///
/// Option (b): `ext.surya` deliberately stays on the 0.17.x classical det+rec
/// generation. The point of these tests is that the decision is a LABEL that
/// travels with the engine — not a sentence in a doc nobody reads at
/// recommend time.
struct SuryaPinTests {
    @Test func suryaCarriesTheDeliberatePinLabel() throws {
        let note = ExternalToolEngine.surya().tradeoffNote
        let text = try #require(note)
        // Names the pinned generation, the reason, and the successor's identity
        // as a SEPARATE candidate — the three facts a reader needs.
        #expect(text.contains("0.17"))
        #expect(text.contains("no model server"))
        #expect(text.contains("surya-2"))
        #expect(text.contains("#29"))
    }

    /// The label is a decision about surya specifically, not a blanket applied
    /// to every classic adapter.
    @Test func otherClassicEnginesCarryNoAccidentalLabel() {
        #expect(ExternalToolEngine.rapidocr().tradeoffNote == nil)
        #expect(ExternalToolEngine.cnocr().tradeoffNote == nil)
    }

    /// Reachability: the label must survive dispatch through `any OCREngine`
    /// (the pitfall #16's tradeoffNote design exists to prevent) and appear in
    /// recommend's entry for ext.surya — including evidence-pending listings,
    /// where a pinned engine spends its life.
    @Test func pinLabelReachesRecommendOutput() throws {
        let registry = EngineRegistry(engines: [ExternalToolEngine.surya()])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "scanned_doc"),
            registry: registry, evidence: EvidenceStore(rows: []))
        let entry = try #require(answer.entries.first)
        #expect(entry.note.contains("tradeoff:"))
        #expect(entry.note.contains("0.17"))
    }

    /// The install hint must not silently install the other generation:
    /// a bare `pip install surya-ocr` today yields 0.22.x, which is not the
    /// engine this roster entry describes.
    @Test func installHintPinsTheGenerationItActuallyInstalls() {
        #expect(ExternalToolEngine.surya().installHint.contains("<0.20"))
    }
}
