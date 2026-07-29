import Foundation
import Testing
@testable import BestOCRKit

/// #17 phase 5 — ROVER-style sequence combination.
///
/// The reason this could not be a drop-in adjudicator: `AlignedItem`'s
/// documented semantics are that an engine absent from `responses` *did not
/// produce an alignable answer*, which **conflates a deletion with a
/// non-alignment**. A confusion network exists precisely to keep those apart,
/// so ROVER gets its own input path and its own protocol.
struct ROVERTests {

    private func network(_ sequences: [String: [String]], page: Int = 1) -> ConfusionNetwork {
        ConfusionNetworkBuilder.build(page: page, sequences: sequences)
    }

    /// The capability item-level adjudication cannot express: one engine drops
    /// a token, another inserts one, and the vote still recovers the sequence.
    @Test func recoversASequenceAcrossAnInsertionAndADeletion() {
        let net = network([
            "A": ["the", "quick", "brown", "fox"],
            "B": ["the", "quick", "brown", "fox"],
            "C": ["the", "brown", "fox"],            // deletion of "quick"
            "D": ["the", "quick", "very", "brown", "fox"],  // insertion of "very"
        ])
        let est = ROVERAdjudicator().adjudicate(network: net)

        #expect(est.adjudicator == "rover")
        let combined = est.items.filter { !$0.lowConsensus || $0.consensusText != ROVERAdjudicator.epsilon }
            .map(\.consensusText)
            .filter { $0 != ROVERAdjudicator.epsilon }
            .joined(separator: " ")
        #expect(combined == "the quick brown fox",
                "majority over slots must drop the lone insertion and restore the lone deletion (got \"\(combined)\")")
    }

    /// A deletion must be a *vote*, not an absence. The slot where C dropped a
    /// token has to contain C with an explicit epsilon.
    @Test func aDeletionIsAnExplicitVoteNotAMissingEntry() {
        let net = network(["A": ["x", "y"], "B": ["x", "y"], "C": ["x"]])
        // Every slot names every engine — that is the whole point of the network.
        for slot in net.slots {
            #expect(Set(slot.alternatives.keys) == ["A", "B", "C"],
                    "each slot must record every engine, epsilon included")
        }
        let ySlot = net.slots.first { $0.alternatives["A"] == "y" }
        #expect(ySlot?.alternatives["C"] == ROVERAdjudicator.epsilon,
                "C's deletion must be an epsilon vote, not an absent key")
    }

    /// Unanimous input must round-trip unchanged.
    @Test func unanimousSequencesRoundTrip() {
        let net = network(["A": ["a", "b"], "B": ["a", "b"], "C": ["a", "b"]])
        let est = ROVERAdjudicator().adjudicate(network: net)
        #expect(est.items.map(\.consensusText) == ["a", "b"])
        #expect(est.items.allSatisfy { !$0.lowConsensus })
    }

    /// ROVER's item is a TOKEN SLOT, not a line — so its low-consensus share is
    /// a share of tokens. That is a different quantity from every item-level
    /// adjudicator's, which is exactly why the estimand name carries the
    /// adjudicator id.
    @Test func itsEstimandIsItsOwnBecauseItsItemIsATokenNotALine() {
        #expect(Estimand.consensus("rover", "low_consensus_share")
                == "consensus.rover.low_consensus_share@v1")
        #expect(Estimand.consensus("rover", "low_consensus_share")
                != Estimand.consensus("ds-lite", "low_consensus_share"))
    }

    /// A 2-way disagreement with no majority must be flagged, not silently
    /// resolved.
    @Test func tiedSlotsAreFlaggedForReview() {
        let net = network(["A": ["left"], "B": ["right"]])
        let est = ROVERAdjudicator().adjudicate(network: net)
        #expect(est.items.count == 1 && est.items[0].lowConsensus)
    }

    @Test func emptyInputIsSafe() {
        let est = ROVERAdjudicator().adjudicate(network: ConfusionNetwork(page: 1, slots: []))
        #expect(est.items.isEmpty)
    }

    @Test func isDiscoverableAsASequenceAdjudicator() {
        #expect(AdjudicatorRegistry.allIDs.contains("rover"))
        #expect(AdjudicatorRegistry.isSequenceAdjudicator("rover"))
        #expect(!AdjudicatorRegistry.isSequenceAdjudicator("ds-lite"))
        #expect(AdjudicatorRegistry.catalogue.contains { $0.id == "rover" })
    }
}
