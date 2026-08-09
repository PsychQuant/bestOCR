import Foundation
import Testing
@testable import BestOCRKit

/// #17 phase 2 — full Dawid-Skene. The claim under test is narrow and specific:
/// ds-lite scores an engine with one scalar per kind, so it can see *that* an
/// engine errs but never *how*. A systematic `0`→`O` reader and a random
/// guesser with the same error rate are indistinguishable to it. Full DS keeps
/// a directional character-level confusion model, so they are not.
struct FullDawidSkeneTests {

    private func item(_ index: Int, _ responses: [String: String],
                      kind: ItemKind = .proseLine) -> AlignedItem {
        AlignedItem(key: ItemKey(page: 1, index: index, kind: kind), responses: responses)
    }

    /// #38 R1 V2: ds-full computes the informative-item count in the SAME
    /// loop as its Laplace competence and used to drop it — `--adjudicator
    /// ds-full` printed the bare `0.500` shape #38 exists to kill.
    @Test func carriesInformativeItemCountsWithCompetence() {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            items.append(item(i, ["A": "line \(i)", "B": "line \(i)"]))
        }
        let est = FullDawidSkeneAdjudicator().adjudicate(items: items)
        #expect(est.diagnostics.overallCompetence?["A"] != nil)
        #expect(est.diagnostics.informativeItems?["A"] == 10,
                "n must travel with the figure — same loop, same denominator")
        #expect(est.diagnostics.informativeItems?["B"] == 10)
    }

    /// The capability ds-lite structurally cannot have. `C` reads every zero as
    /// a capital O and is otherwise correct; A and B carry the truth.
    @Test func recoversAPlantedDirectionalConfusion() {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            let truth = "code 0\(i) ok"
            items.append(item(i, ["A": truth, "B": truth,
                                  "C": truth.replacingOccurrences(of: "0", with: "O")]))
        }

        let est = FullDawidSkeneAdjudicator().adjudicate(items: items)

        #expect(est.adjudicator == "ds-full")
        let confusion = est.diagnostics.confusion
        #expect(confusion != nil, "ds-full HAS a confusion model — that is its reason to exist")

        // C's mass for true "0" must sit on observed "O", not on "0".
        let cZero = confusion?["C"]?["0"] ?? [:]
        #expect((cZero["O"] ?? 0) > (cZero["0"] ?? 0),
                "C systematically reads 0 as O — the confusion row must say so (got \(cZero))")

        // A is clean: its mass for true "0" stays on "0".
        let aZero = confusion?["A"]?["0"] ?? [:]
        #expect((aZero["0"] ?? 0) > (aZero["O"] ?? 0), "A reads zeros correctly (got \(aZero))")
    }

    /// The distinction the whole design rests on, at the confusion field:
    /// ds-lite reports `nil` (no such notion), ds-full reports a model.
    @Test func dsLiteHasNoConfusionModelAndSaysSo() {
        let items = [item(0, ["A": "same", "B": "same", "C": "same"])]
        #expect(DawidSkeneLiteAdjudicator().adjudicate(items: items).diagnostics.confusion == nil,
                "ds-lite has no confusion concept — nil, not an empty map")
        #expect(FullDawidSkeneAdjudicator().adjudicate(items: items).diagnostics.confusion != nil)
    }

    /// On unanimous input there is nothing to adjudicate, so a richer model
    /// must not invent a different answer.
    @Test func agreesWithDsLiteWhenThereIsNoDisagreement() {
        let items = (0..<5).map { i in
            item(i, ["A": "line \(i)", "B": "line \(i)", "C": "line \(i)"])
        }
        let full = FullDawidSkeneAdjudicator().adjudicate(items: items)
        let lite = DawidSkeneLiteAdjudicator().adjudicate(items: items)
        #expect(full.items.map(\.consensusText) == lite.items.map(\.consensusText))
    }

    /// A single-engine item has nothing corroborating it, whichever model runs.
    @Test func soloAndTiedItemsStayFlaggedForReview() {
        let solo = FullDawidSkeneAdjudicator().adjudicate(items: [item(0, ["A": "only"])])
        #expect(solo.items.count == 1 && solo.items[0].lowConsensus)

        let tie = FullDawidSkeneAdjudicator().adjudicate(items: [item(0, ["A": "left", "B": "right"])])
        #expect(tie.items.count == 1 && tie.items[0].lowConsensus)
    }

    /// Empty / placeholder-only input must not trap the estimator.
    @Test func emptyInputIsSafe() {
        let est = FullDawidSkeneAdjudicator().adjudicate(items: [])
        #expect(est.items.isEmpty)
        #expect(est.diagnostics.confusion?.isEmpty == true,
                "concept exists, nothing to report — not nil")
    }

    /// Selectable like every other adjudicator, and its estimand name is its own.
    @Test func isRegisteredAndNamesItsOwnEstimand() {
        #expect(AdjudicatorRegistry.allIDs.contains("ds-full"))
        #expect(AdjudicatorRegistry.make("ds-full")?.id == "ds-full")
        #expect(Estimand.consensus("ds-full", "low_consensus_share")
                == "consensus.ds_full.low_consensus_share@v1")
    }

    /// Alignment is what makes the character model possible; it must represent
    /// insertions and deletions rather than silently truncating.
    @Test func characterAlignmentRepresentsIndels() {
        let pairs = FullDawidSkeneAdjudicator.alignForTesting(truth: "abc", observed: "ac")
        // One of the pairs must be a deletion: true 'b' observed as nothing.
        #expect(pairs.contains { $0.trueChar == "b" && $0.observed == FullDawidSkeneAdjudicator.epsilon })
        let ins = FullDawidSkeneAdjudicator.alignForTesting(truth: "ac", observed: "abc")
        #expect(ins.contains { $0.trueChar == FullDawidSkeneAdjudicator.epsilon && $0.observed == "b" })
    }
}
