import Foundation
import Testing
@testable import BestOCRKit

/// #17 phase 0/0b/1 — the adjudicator becomes a pluggable, honestly-labelled
/// choice. These tests pin the two claims the design rests on:
///
/// 1. `nil` (this model has no such notion) is distinguishable from an empty
///    collection (it has the notion, nothing to report). Without this, a
///    naive-majority report reads like a degenerate Dawid-Skene one.
/// 2. Different adjudicators produce differently-*named* estimands, so their
///    numbers can never be cross-ranked by `evidence/schema.md` hard rule 2.
struct ConsensusAdjudicatorTests {

    private func item(_ index: Int, _ responses: [String: String],
                      kind: ItemKind = .proseLine) -> AlignedItem {
        AlignedItem(key: ItemKey(page: 1, index: index, kind: kind), responses: responses)
    }

    /// The refactor must not change what Dawid-Skene-lite computes. Same
    /// fixture and same expectations as `ConsensusEstimatorTests`, run through
    /// the new protocol surface.
    @Test func dsLitePreservesBehaviourThroughTheProtocol() {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            let t = "t\(i)"
            var responses = ["A": t, "B": t, "C": t]
            if i == 4 || i == 5 { responses["B"] = "b-garbage-\(i)" }
            if i >= 6 { responses["C"] = "c-garbage-\(i)" }
            items.append(item(i, responses))
        }

        let viaProtocol = DawidSkeneLiteAdjudicator().adjudicate(items: items)
        let direct = ConsensusEstimator.estimate(items: items)

        #expect(viaProtocol.adjudicator == "ds-lite")
        #expect(viaProtocol.items.map(\.consensusText) == direct.items.map(\.consensusText))
        #expect(viaProtocol.diagnostics.overallCompetence == direct.diagnostics.overallCompetence)
        #expect(viaProtocol.diagnostics.competence == direct.diagnostics.competence)
    }

    /// The load-bearing distinction. Majority has no competence concept at all
    /// (`nil`); DS-lite has the concept and reports it.
    @Test func nilMeansNoSuchNotionNotEmpty() {
        let items = [item(0, ["A": "same", "B": "same", "C": "same"])]

        let majority = MajorityAdjudicator().adjudicate(items: items)
        #expect(majority.diagnostics.overallCompetence == nil,
                "majority has no competence concept — must be nil, not [:]")
        #expect(majority.diagnostics.competence == nil)
        #expect(majority.diagnostics.iterations == nil, "majority is not iterative")
        #expect(majority.diagnostics.converged == nil)

        let dsLite = DawidSkeneLiteAdjudicator().adjudicate(items: items)
        #expect(dsLite.diagnostics.overallCompetence != nil,
                "ds-lite HAS the concept — must be non-nil even if sparse")
        #expect(dsLite.diagnostics.iterations != nil)
    }

    /// DS-lite has the competence notion; when every item is uninformative it
    /// reports an EMPTY map — which must not be confused with majority's nil.
    @Test func emptyMeansNothingToReportNotAbsentConcept() {
        // Two engines disagreeing on the only item: top-weight tie, so the item
        // is uninformative and no engine earns a per-kind competence entry.
        let est = DawidSkeneLiteAdjudicator().adjudicate(items: [item(0, ["A": "l", "B": "r"])])
        #expect(est.diagnostics.competence != nil, "concept exists")
        #expect(est.diagnostics.competence?.isEmpty == true, "…but nothing qualified")
    }

    /// The agreement matrix is computed from raw responses, so it is
    /// adjudicator-independent and stays comparable across all of them.
    @Test func agreementMatrixIsAdjudicatorIndependent() {
        let items = [item(0, ["A": "x", "B": "x", "C": "y"]),
                     item(1, ["A": "p", "B": "q", "C": "p"])]
        let a = MajorityAdjudicator().adjudicate(items: items).agreement
        let b = DawidSkeneLiteAdjudicator().adjudicate(items: items).agreement
        #expect(a == b, "agreement is a raw-response diagnostic, not a model output")
    }

    /// The control's whole purpose: when one engine is unreliable, competence
    /// weighting must actually change a verdict. If it never does, the CCT
    /// family's benefit on this corpus is asserted rather than measured.
    /// The control's whole purpose. A and B are reliable; C and D are noisy but
    /// **independently** so on the training items, which lets A+B carry a
    /// 2-vs-1-vs-1 majority and earn competence. On the last item C and D
    /// happen to coincide, producing a 2–2 count tie: plurality has nothing to
    /// break it with and falls to lexicographic order, while competence
    /// weighting resolves it toward the demonstrably reliable pair.
    ///
    /// The fixture is deliberate: an earlier version had C and D colliding on
    /// *every* item, which makes every item a top-weight tie, so ds-lite never
    /// learns any competence and both models pick the same lexicographic
    /// winner. That is not a bug — it is exactly the correlated-error limit
    /// spec §8 records, and the reason `agreement` stays in every report.
    @Test func majorityAndDsLiteCanDisagreeWhenAnEngineIsUnreliable() {
        var items: [AlignedItem] = []
        for i in 0..<8 {
            let t = "t\(i)"
            items.append(item(i, ["A": t, "B": t, "C": "c-junk-\(i)", "D": "d-junk-\(i)"]))
        }
        // "junk" < "truth" lexicographically, so an unweighted tie-break picks
        // the wrong answer — which is what makes the difference observable.
        items.append(item(8, ["A": "truth", "B": "truth", "C": "junk", "D": "junk"]))

        let maj = MajorityAdjudicator().adjudicate(items: items)
        let ds = DawidSkeneLiteAdjudicator().adjudicate(items: items)

        #expect(maj.items.count == ds.items.count)
        #expect(ds.items[8].consensusText == "truth",
                "competence weighting should favour the demonstrably reliable pair")
        #expect(maj.items[8].consensusText == "junk",
                "plurality has no competence to break a 2–2 tie — it falls to lexicographic order")
        #expect(maj.items[8].consensusText != ds.items[8].consensusText,
                "the control must be able to differ, or its benefit is untestable")
    }

    /// Estimand names must be mechanically un-mixable across adjudicators.
    @Test func estimandNamesAreDistinctPerAdjudicator() {
        let dsLite = Estimand.consensus("ds-lite", "low_consensus_share")
        let majority = Estimand.consensus("majority", "low_consensus_share")
        #expect(dsLite == "consensus.ds_lite.low_consensus_share@v1")
        #expect(majority == "consensus.majority.low_consensus_share@v1")
        #expect(dsLite != majority)
    }

    /// Rows written before adjudicators were pluggable carry the unqualified
    /// name. They were all produced by ds-lite — the only adjudicator that ever
    /// existed — so mapping them is history, not an assumption.
    @Test func legacyUnqualifiedConsensusNameReadsAsDsLite() {
        #expect(Estimand.canonicalConsensus("consensus.low_consensus_share@v1")
                == "consensus.ds_lite.low_consensus_share@v1")
        // An already-qualified name is untouched.
        #expect(Estimand.canonicalConsensus("consensus.majority.low_consensus_share@v1")
                == "consensus.majority.low_consensus_share@v1")
        // Non-consensus estimands fall through to plain version canonicalization.
        #expect(Estimand.canonicalConsensus("speed.ms_per_page") == "speed.ms_per_page@v1")
    }

    /// Every registered adjudicator must be reachable by its own id, and ids
    /// must be unique — the registry is what the CLI/MCP selection binds to.
    @Test func registryResolvesEveryAdjudicatorById() {
        let ids = AdjudicatorRegistry.allIDs
        #expect(ids.contains("ds-lite") && ids.contains("majority"))
        #expect(Set(ids).count == ids.count, "ids must be unique")
        for id in ids {
            #expect(AdjudicatorRegistry.make(id)?.id == id)
        }
        #expect(AdjudicatorRegistry.make("no-such-adjudicator") == nil)
    }
}
