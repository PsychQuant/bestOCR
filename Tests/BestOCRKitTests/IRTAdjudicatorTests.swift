import Foundation
import Testing
@testable import BestOCRKit

/// #17 phase 4 — IRT adjudication. The distinctive capability: **items differ
/// in difficulty**, and a model that ignores that credits an engine equally for
/// getting an easy line right and a hard one right.
///
/// Rasch form: `P(engine e matches truth on item i) = σ(θ_e − b_i)`.
struct IRTAdjudicatorTests {

    private func item(_ index: Int, _ responses: [String: String]) -> AlignedItem {
        AlignedItem(key: ItemKey(page: 1, index: index, kind: .proseLine), responses: responses)
    }

    /// The quantity no other adjudicator produces: a per-item difficulty. An
    /// item everyone agrees on must come out easier than one most engines miss.
    @Test func estimatesItemDifficultyAndEasyItemsScoreLower() {
        var items: [AlignedItem] = []
        // Items 0-4: unanimous — easy.
        for i in 0..<5 { items.append(item(i, ["A": "t\(i)", "B": "t\(i)", "C": "t\(i)"])) }
        // Items 5-9: only A gets it; B and C each go their own way — hard.
        for i in 5..<10 {
            items.append(item(i, ["A": "t\(i)", "B": "b-\(i)", "C": "c-\(i)"]))
        }

        let est = IRTAdjudicator().adjudicate(items: items)
        #expect(est.adjudicator == "irt")

        let params = est.diagnostics.itemParameters
        #expect(params != nil, "IRT reports per-item latent parameters — that is its reason to exist")
        #expect(params?.count == items.count)

        func difficulty(_ index: Int) -> Double {
            params?.first { $0.key.index == index }?.parameters["difficulty"] ?? .nan
        }
        let easy = (0..<5).map(difficulty).reduce(0, +) / 5
        let hard = (5..<10).map(difficulty).reduce(0, +) / 5
        #expect(easy < hard, "unanimous items must be estimated easier (easy \(easy), hard \(hard))")
    }

    /// Rasch is additively indeterminate: (θ + c, b + c) fits identically. The
    /// implementation must anchor the scale, or the reported numbers are only
    /// meaningful up to an unstated constant.
    @Test func difficultyScaleIsAnchoredSoTheNumbersAreComparable() {
        let items = (0..<6).map { i in item(i, ["A": "t\(i)", "B": "t\(i)", "C": "x\(i)"]) }
        let params = IRTAdjudicator().adjudicate(items: items).diagnostics.itemParameters ?? []
        let mean = params.compactMap { $0.parameters["difficulty"] }.reduce(0, +) / Double(params.count)
        #expect(abs(mean) < 1e-6, "difficulties must be mean-centred to fix the Rasch indeterminacy (got \(mean))")
    }

    /// Ability must track observed accuracy, not just agreement count.
    ///
    /// Fixture discipline (this is the third time in #17 a fixture, not the
    /// code, was the bug): **every error must be outvoted by a 2-engine
    /// coalition carrying the truth.** An earlier version had all three engines
    /// disagree on the last item, which leaves no majority — the lexicographic
    /// tie-break then elected a *wrong* answer as the assigned truth and the
    /// engine that produced it was rewarded for it. That is the cold-start
    /// limit every adjudicator here shares, not an IRT defect, but it makes the
    /// fixture untestable. So each miss is committed by exactly one engine.
    @Test func abilityOrdersEnginesByPerformance() {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            let t = "t\(i)"
            var r = ["A": t, "B": t, "C": t]
            if (6...8).contains(i) { r["C"] = "c-wrong-\(i)" }   // C misses 3 (A+B carry truth)
            if i == 9 { r["B"] = "b-wrong-\(i)" }                // B misses 1 (A+C carry truth)
            items.append(item(i, r))
        }
        let est = IRTAdjudicator().adjudicate(items: items)
        let ability = est.diagnostics.overallCompetence ?? [:]
        #expect((ability["A"] ?? 0) > (ability["B"] ?? 0))
        #expect((ability["B"] ?? 0) > (ability["C"] ?? 0))
    }

    /// It has a competence notion and an item-parameter notion; it has no
    /// confusion model, and must say so rather than reporting an empty one.
    @Test func reportsWhatItHasAndNilsWhatItDoesNot() {
        let est = IRTAdjudicator().adjudicate(items: [item(0, ["A": "x", "B": "x"])])
        #expect(est.diagnostics.overallCompetence != nil)
        #expect(est.diagnostics.itemParameters != nil)
        #expect(est.diagnostics.confusion == nil, "IRT has no confusion model — nil, not [:]")
        #expect(est.diagnostics.priorCompetence == nil, "nothing was handed to it")
        #expect(est.diagnostics.iterations != nil, "it is iterative")
    }

    @Test func emptyInputIsSafe() {
        let est = IRTAdjudicator().adjudicate(items: [])
        #expect(est.items.isEmpty)
        #expect(est.diagnostics.itemParameters?.isEmpty == true,
                "concept exists, nothing to report — not nil")
    }

    @Test func isRegisteredAndSelectable() {
        #expect(AdjudicatorRegistry.allIDs.contains("irt"))
        #expect(AdjudicatorRegistry.make("irt")?.id == "irt")
        #expect(Estimand.consensus("irt", "low_consensus_share")
                == "consensus.irt.low_consensus_share@v1")
    }
}
