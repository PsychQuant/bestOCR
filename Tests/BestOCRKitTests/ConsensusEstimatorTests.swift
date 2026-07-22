import Foundation
import Testing
@testable import BestOCRKit

/// Synthetic-informant recovery tests (#11): known competence structure must be
/// recovered by the Dawid-Skene-lite estimator. Cases are small and exact —
/// consensus and competence orderings are hand-computable, no Monte Carlo.
struct ConsensusEstimatorTests {

    /// Build a prose item answered by the given engines.
    private func item(_ index: Int, _ responses: [String: String]) -> AlignedItem {
        AlignedItem(key: ItemKey(page: 1, index: index, kind: .proseLine),
                    responses: responses)
    }

    @Test func recoversTruthAndCompetenceOrdering() {
        // Truth t0..t9. A correct on 10/10, B on 8/10, C on 6/10.
        // Identifiability note (r2 — fixture corrected): every error must be
        // outvoted by a 2-engine coalition, else the A-vs-B ordering is not
        // recoverable from the response matrix alone. Items 0-3: unanimous.
        // 4-5: B garbage, A+C coalition carries truth. 6-9: C garbage, A+B
        // coalition carries truth.
        var items: [AlignedItem] = []
        for i in 0..<10 {
            let t = "t\(i)"
            var responses = ["A": t, "B": t, "C": t]
            if i == 4 || i == 5 { responses["B"] = "b-garbage-\(i)" }
            if i >= 6 { responses["C"] = "c-garbage-\(i)" }
            items.append(item(i, responses))
        }

        let est = ConsensusEstimator.estimate(items: items)

        for (i, ic) in est.items.enumerated() {
            #expect(ic.consensusText == "t\(i)", "item \(i) consensus should be truth")
        }
        let a = est.overallCompetence["A"] ?? 0
        let b = est.overallCompetence["B"] ?? 0
        let c = est.overallCompetence["C"] ?? 0
        #expect(a > b && b > c, "competence ordering A > B > C (got \(a), \(b), \(c))")
        #expect(est.iterations >= 1 && est.iterations <= 20)
    }

    @Test func twoWayTieIsLowConsensus() {
        // Two engines, one item, disagreeing with equal weight — no basis to
        // adjudicate. Must be flagged, and deterministically resolved.
        let items = [item(0, ["A": "left", "B": "right"])]
        let est = ConsensusEstimator.estimate(items: items)
        #expect(est.items.count == 1)
        #expect(est.items[0].lowConsensus, "equal-weight tie must flag lowConsensus")
    }

    @Test func singleResponseItemIsLowConsensus() {
        // Only one engine answered — nothing corroborates. Consensus text is
        // that response, but the item must be flagged for human review.
        let items = [
            item(0, ["A": "alone"]),
            item(1, ["A": "x", "B": "x", "C": "x"]),
        ]
        let est = ConsensusEstimator.estimate(items: items)
        #expect(est.items[0].consensusText == "alone")
        #expect(est.items[0].lowConsensus, "uncorroborated item must flag lowConsensus")
        #expect(!est.items[1].lowConsensus, "unanimous 3-engine item is high consensus")
    }

    @Test func perKindCompetenceSeparates() {
        // Engine B is perfect on prose but always wrong on table cells;
        // A and C are perfect everywhere. Per-kind competence must reflect it.
        var items: [AlignedItem] = []
        for i in 0..<6 {
            items.append(item(i, ["A": "p\(i)", "B": "p\(i)", "C": "p\(i)"]))
        }
        for i in 0..<6 {
            let key = ItemKey(page: 1, index: 100 + i, kind: .tableCell)
            items.append(AlignedItem(key: key,
                                     responses: ["A": "0.03\(i)", "B": "9.99\(i)", "C": "0.03\(i)"]))
        }
        let est = ConsensusEstimator.estimate(items: items)
        let bProse = est.competence["B"]?[.proseLine] ?? 0
        let bCell = est.competence["B"]?[.tableCell] ?? 0
        #expect(bProse > bCell, "B prose competence (\(bProse)) must exceed cell competence (\(bCell))")
        let aCell = est.competence["A"]?[.tableCell] ?? 0
        #expect(aCell > bCell, "A cell competence must exceed B cell competence")
    }

    @Test func soloItemsDoNotInflateCompetence() {
        // Verify #11 finding 2: a solo item's winner is trivially its own
        // response — counting it as "correct" in the M-step lets an engine
        // that hallucinates many uncorroborated lines outrank engines that
        // are right on every co-answered item. Uncorroborated items carry no
        // information about accuracy and must not enter competence.
        var items: [AlignedItem] = []
        for i in 0..<4 {
            items.append(item(i, ["A": "t\(i)", "B": "t\(i)", "C": "c-wrong-\(i)"]))
        }
        for i in 0..<30 {
            items.append(item(100 + i, ["C": "solo-\(i)"]))
        }
        let est = ConsensusEstimator.estimate(items: items)
        let a = est.overallCompetence["A"] ?? 0
        let c = est.overallCompetence["C"] ?? 0
        #expect(c < a, "30 hallucinated solo lines must not outrank a 4/4-correct engine (A \(a), C \(c))")
    }

    @Test func reportedCompetenceIsConsistentWithReportedVerdicts() {
        // Verify #11 finding 3: the published overall competence must be
        // recomputable from the published verdicts — over non-lowConsensus
        // items only, (matches + 1) / (n + 2) — even when the iteration cap
        // interrupts EM mid-stride.
        var items: [AlignedItem] = []
        for i in 0..<6 {
            var r = ["A": "t\(i)", "B": "t\(i)", "C": "t\(i)"]
            if i.isMultiple(of: 2) { r["C"] = "z\(i)" }
            items.append(item(i, r))
        }
        items.append(item(100, ["C": "solo"]))
        for maxIter in [1, 2, 20] {
            let est = ConsensusEstimator.estimate(items: items, maxIterations: maxIter)
            let informative = est.items.filter { !$0.lowConsensus }
            for (engine, reported) in est.overallCompetence {
                var n = 0, correct = 0
                for v in informative {
                    guard let r = v.responses[engine] else { continue }
                    n += 1
                    if r == v.consensusText { correct += 1 }
                }
                let expected = Double(correct + 1) / Double(n + 2)
                #expect(abs(reported - expected) < 1e-12,
                        "\(engine) @maxIter=\(maxIter): reported \(reported), recomputed \(expected)")
            }
        }
    }

    @Test func convergedFlagReportsFixedPointVsCap() {
        // Hitting maxIterations is not convergence — the caller must be able
        // to tell a fixed point from a cap-interrupted run.
        var items: [AlignedItem] = []
        for i in 0..<3 {
            items.append(item(i, ["A": "t\(i)", "B": "t\(i)", "C": "t\(i)"]))
        }
        let full = ConsensusEstimator.estimate(items: items)
        #expect(full.converged, "unanimous fixture must reach a fixed point")
        let capped = ConsensusEstimator.estimate(items: items, maxIterations: 1)
        #expect(!capped.converged, "cap hit before the stability check must report converged=false")
    }

    @Test func emptyResponsesItemIsSkippedNotTrapped() {
        // estimate() is public API — an AlignedItem with no responses must
        // not trap in weightedWinner (ranked[0] on an empty tally).
        let empty = AlignedItem(key: ItemKey(page: 1, index: 0, kind: .proseLine),
                                responses: [:])
        let real = item(1, ["A": "x", "B": "x"])
        let est = ConsensusEstimator.estimate(items: [empty, real])
        #expect(est.items.count == 1, "empty-response item carries no signal and is dropped")
        #expect(est.items.first?.consensusText == "x")
    }

    @Test func agreementDiagnosticIsSymmetricAndBounded() {
        // Pairwise raw agreement: A,B always agree; C never agrees with them.
        var items: [AlignedItem] = []
        for i in 0..<4 {
            items.append(item(i, ["A": "s\(i)", "B": "s\(i)", "C": "z\(i)"]))
        }
        let est = ConsensusEstimator.estimate(items: items)
        let ab = est.agreement["A"]?["B"] ?? -1
        let ba = est.agreement["B"]?["A"] ?? -1
        let ac = est.agreement["A"]?["C"] ?? -1
        #expect(ab == 1.0 && ba == 1.0, "A-B agreement must be 1.0 and symmetric")
        #expect(ac == 0.0, "A-C agreement must be 0.0")
    }
}
