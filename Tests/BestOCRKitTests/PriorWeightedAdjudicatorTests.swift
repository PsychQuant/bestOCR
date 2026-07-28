import Foundation
import Testing
@testable import BestOCRKit

/// #17 phase 3 — prior-weighted vote. The adjudicator that closes the loop
/// between the benchmark and the consensus layer: instead of estimating
/// competence only from within-item agreement (which a colluding pair can
/// dominate), it takes measured `word_recall` as a **fixed** prior.
struct PriorWeightedAdjudicatorTests {

    private func item(_ index: Int, _ responses: [String: String]) -> AlignedItem {
        AlignedItem(key: ItemKey(page: 1, index: index, kind: .proseLine), responses: responses)
    }

    private func row(estimand: String, value: Double, model: String,
                     tier: String = "T2", platform: String = "ollama") -> EvidenceRow {
        EvidenceRow(estimand: estimand, value: value,
                    condition: ConditionTuple(model: model, quant: "q8_0", dpi: 150,
                                              docType: "scanned_doc", platform: platform,
                                              hardware: "test", instrument: "test"),
                    tier: tier, source: "fixture")
    }

    /// The prior must actually decide a vote the counts cannot. Two engines
    /// agree on a wrong answer; one measured-better engine dissents.
    @Test func measuredPriorOutvotesAColludingPair() {
        let prior = ["good": 0.99, "bad1": 0.30, "bad2": 0.30]
        let est = PriorWeightedAdjudicator(prior: prior)
            .adjudicate(items: [item(0, ["good": "truth", "bad1": "wrong", "bad2": "wrong"])])

        #expect(est.adjudicator == "prior-weighted")
        #expect(est.items[0].consensusText == "truth",
                "0.99 must outweigh 0.30 + 0.30 — a measured prior is the point")
    }

    /// A prior is an **input**, not an estimate. Reporting it as
    /// `overallCompetence` would claim this model measured something it was
    /// handed, so it lands in its own field and the estimated one stays nil.
    @Test func priorIsReportedAsAPriorNotAsEstimatedCompetence() {
        let est = PriorWeightedAdjudicator(prior: ["a": 0.9, "b": 0.5])
            .adjudicate(items: [item(0, ["a": "x", "b": "x"])])
        #expect(est.diagnostics.overallCompetence == nil,
                "this model does not ESTIMATE competence — nil, not the prior echoed back")
        #expect(est.diagnostics.priorCompetence?["a"] == 0.9)
        #expect(est.diagnostics.iterations == nil, "one-shot: no EM")
        #expect(est.diagnostics.confusion == nil)
    }

    /// Acyclicity (spec §10): a prior built from evidence must exclude rows the
    /// consensus layer itself produced, or an engine's prior inflates its
    /// influence, which inflates its measured agreement, which feeds back.
    @Test func evidenceDerivedPriorExcludesConsensusRows() {
        let store = EvidenceStore(rows: [
            row(estimand: "quality.word_recall", value: 0.95, model: "vision"),
            row(estimand: "quality.word_recall", value: 0.80, model: "tesseract"),
            // Consensus-derived: MUST NOT become a prior for anything.
            row(estimand: "consensus.ds_lite.low_consensus_share@v1", value: 0.1,
                model: "consensus", platform: "consensus"),
            // Wrong tier: vendor claims are not our measurements.
            row(estimand: "quality.word_recall", value: 0.99, model: "ext.surya", tier: "T3"),
        ])
        let built = PriorWeightedAdjudicator.fromEvidence(store, engineIDs: ["vision", "tesseract", "ext.surya"])

        #expect(built.prior["vision"] == 0.95)
        #expect(built.prior["tesseract"] == 0.80)
        // `consensus` was never a requested engine, so it gets no weight at all.
        #expect(built.prior["consensus"] == nil, "consensus-derived rows must never seed a prior")
        // A T3 row is rejected as a MEASUREMENT, but the engine still gets a
        // weight — silently giving it zero would be a different lie. It falls
        // back to the neutral prior and is disclosed as assumed.
        #expect(built.prior["ext.surya"] == PriorWeightedAdjudicator.neutralPrior,
                "T3 vendor claims are not a measured prior — neutral, not absent")
        #expect(built.assumedEngines.contains("ext.surya"),
                "an engine running on an assumption must be nameable in the report")
        #expect(!built.assumedEngines.contains("vision"))
    }

    /// An engine with no measured row must not be silently treated as perfect
    /// or as worthless — it falls back to the neutral prior, and the report
    /// says which engines were assumed rather than measured.
    @Test func enginesWithoutMeasurementFallBackNeutrallyAndAreDisclosed() {
        let store = EvidenceStore(rows: [row(estimand: "quality.word_recall", value: 0.9, model: "vision")])
        let built = PriorWeightedAdjudicator.fromEvidence(store, engineIDs: ["vision", "unmeasured"])
        #expect(built.prior["vision"] == 0.9)
        #expect(built.prior["unmeasured"] == PriorWeightedAdjudicator.neutralPrior)
        #expect(built.assumedEngines == ["unmeasured"],
                "engines running on an assumed prior must be nameable in the report")
    }

    /// Versioned and unversioned estimand names denote the same thing, so a
    /// legacy row must still be usable as a prior (#16's `Estimand.canonical`).
    @Test func legacyUnversionedWordRecallRowsStillCount() {
        let store = EvidenceStore(rows: [
            row(estimand: "quality.word_recall@v1", value: 0.88, model: "vision"),
        ])
        #expect(PriorWeightedAdjudicator.fromEvidence(store, engineIDs: ["vision"]).prior["vision"] == 0.88)
    }

    @Test func isRegisteredAndSelectable() {
        #expect(AdjudicatorRegistry.allIDs.contains("prior-weighted"))
        #expect(AdjudicatorRegistry.make("prior-weighted")?.id == "prior-weighted")
    }
}
