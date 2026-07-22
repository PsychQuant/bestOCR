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

    @Test func emptyPlaceholdersDoNotVote() {
        // #13 verify (Codex): positional placeholders ("" cells) must keep
        // their slot but NOT vote — two empty cells would otherwise outvote
        // the only engine that read real content 2:1, and empty↔empty would
        // inflate supporters/competence/agreement.
        let mixed = item(0, ["A": "", "B": "", "C": "5"])
        let allEmpty = item(1, ["A": "", "B": ""])
        let est = ConsensusEstimator.estimate(items: [mixed, allEmpty])
        #expect(est.items.count == 1, "all-empty item carries no signal and is dropped")
        #expect(est.items.first?.consensusText == "5",
                "the only real content wins; empties abstain")
        #expect(est.items.first?.lowConsensus == true,
                "one real supporter is uncorroborated")
    }

    @Test func responsesPreserveRawRendering() {
        // #13 F5: whitespace differences are real OCR signal for the OUTPUT
        // even though voting ignores them — the published responses and the
        // winning transcript text must be raw renderings, not normalized.
        let it = AlignedItem(key: ItemKey(page: 1, index: 0, kind: .proseLine),
                             responses: [
                                "A": ItemResponse(raw: "a  b", normalized: "a b"),
                                "B": ItemResponse(raw: "a  b", normalized: "a b"),
                             ])
        let est = ConsensusEstimator.estimate(items: [it])
        #expect(est.items.first?.consensusText == "a  b",
                "transcript keeps the raw double space")
        #expect(est.items.first?.responses["A"] == "a  b")
        #expect(est.items.first?.lowConsensus == false)
    }

    @Test func mathAndProseRenderingsCorroborateInVoting() {
        // Round-2 finding: alignment put the two renderings on one item, but
        // voting still used raw-string equality — `$E = mc^2$` vs `E = mc^2`
        // stayed a 2-way tie (lowConsensus, excluded from competence).
        // Canonical vote labels must make them the SAME answer; the output
        // keeps a deterministic raw representative.
        let it = AlignedItem(key: ItemKey(page: 1, index: 0, kind: .math),
                             responses: ["paddle": "$E = mc^2$", "vision": "E = mc^2"])
        let est = ConsensusEstimator.estimate(items: [it])
        #expect(est.items.first?.lowConsensus == false,
                "two renderings of one answer must corroborate, not tie")
        #expect(est.items.first?.consensusText == "$E = mc^2$",
                "representative rendering is the lexicographically smallest raw")
    }

    @Test func confidenceIsMeasuredUnderPublishedCompetence() {
        // Round-2 finding: at the iteration cap the verdict confidence was a
        // stale share from the pre-terminal weights. It must be recomputable
        // from the PUBLISHED per-kind competences. (Fixture is math-free, so
        // raw equality is the vote-label relation here.)
        var items: [AlignedItem] = []
        for i in 0..<6 {
            var r = ["A": "t\(i)", "B": "t\(i)", "C": "t\(i)"]
            if i.isMultiple(of: 2) { r["C"] = "z\(i)" }
            items.append(item(i, r))
        }
        items.append(item(50, ["A": "u", "B": "u", "C": "v"]))
        for maxIter in [1, 20] {
            let est = ConsensusEstimator.estimate(items: items, maxIterations: maxIter)
            for v in est.items {
                var winning = 0.0, total = 0.0
                for (engine, resp) in v.responses {
                    let w = est.competence[engine]?[v.key.kind] ?? 0.5
                    total += w
                    if resp == v.consensusText { winning += w }
                }
                let expected = total > 0 ? winning / total : 0
                #expect(abs(v.confidence - expected) < 1e-12,
                        "item \(v.key.index) @maxIter=\(maxIter): confidence \(v.confidence), expected \(expected)")
            }
        }
    }

    @Test func capReversalIsFlaggedLowConsensus() {
        // Round-2 (Codex): at the iteration cap, the published competences
        // can make the published label a LOSER under the report's own
        // weights (EM fixed-point equations can't all hold pre-convergence).
        // Such a verdict must not ship quietly as high-consensus: flag it
        // and keep it out of the competence measurements.
        var items: [AlignedItem] = []
        items.append(item(0, ["A": "X", "B": "X", "C": "Y"]))
        for i in 1...10 {
            items.append(item(i, ["A": "wa\(i)", "B": "wb\(i)", "C": "t\(i)", "D": "t\(i)"]))
        }
        let est = ConsensusEstimator.estimate(items: items, maxIterations: 1)
        #expect(!est.converged)
        let target = est.items.first { $0.key.index == 0 }
        #expect(target?.lowConsensus == true,
                "label that loses under the published competences must be routed to review")
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
                                responses: [String: ItemResponse]())
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
