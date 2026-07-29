import Foundation

/// #17 phase 5 — ROVER-style sequence combination.
///
/// ## Why this needs its own input path
///
/// `AlignedItem` documents its own semantics as: *"An engine absent from
/// `responses` did not produce an alignable answer for this item."* That
/// **conflates a deletion with a non-alignment** — and telling those apart is
/// the entire job of a confusion network. So ROVER does not adjudicate
/// `AlignedItem`s; it adjudicates a `ConfusionNetwork` in which every slot
/// names every engine, with an explicit `epsilon` where an engine produced
/// nothing.
///
/// It returns the same `ConsensusEstimate`, so the report writer, the estimand
/// rules, and the low-consensus review path stay shared. Only the input differs.
///
/// ## Sharing with bestASR
///
/// The aligner and network are written to be liftable into a package shared
/// with the bestASR sibling, which needs the identical component for transcript
/// combination. They are **not** extracted here: a shared package with one
/// consumer is speculative generality, and the seam is cheap to cut later.
public protocol SequenceAdjudicator: Sendable {
    static var id: String { get }
    static var guidance: String { get }
    func adjudicate(network: ConfusionNetwork) -> ConsensusEstimate
}

/// One slot of a confusion network: **every** engine appears, with `epsilon`
/// marking "produced nothing here". An absent key would be the very ambiguity
/// this type exists to remove.
public struct ConfusionSlot: Sendable {
    public let alternatives: [String: String]
    public init(alternatives: [String: String]) { self.alternatives = alternatives }
}

public struct ConfusionNetwork: Sendable {
    public let page: Int
    public let slots: [ConfusionSlot]
    public init(page: Int, slots: [ConfusionSlot]) {
        self.page = page
        self.slots = slots
    }
}

/// Builds a confusion network by aligning each hypothesis onto a growing
/// network, the standard ROVER construction.
///
/// **Order dependence is real and disclosed**: the network depends on the order
/// hypotheses are merged, so engines are processed in sorted id order to make
/// the result deterministic — not because that order is optimal. A full
/// minimum-cost multiple alignment would remove the dependence at much higher
/// cost; this is the same tradeoff the original ROVER makes.
public enum ConfusionNetworkBuilder {

    /// Whitespace tokenization. Coarser than character-level (which would catch
    /// intra-word OCR confusions) and far cheaper; `ds-full` is the adjudicator
    /// that models sub-token errors, so the two cover different ground on
    /// purpose.
    public static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    public static func build(page: Int, sequences: [String: [String]]) -> ConfusionNetwork {
        let engines = sequences.keys.sorted()
        guard let first = engines.first else { return ConfusionNetwork(page: page, slots: []) }

        // Seed the network with the first hypothesis, one token per slot.
        var slots: [[String: String]] = (sequences[first] ?? []).map { [first: $0] }

        for engine in engines.dropFirst() {
            let hypothesis = sequences[engine] ?? []
            // The network's current consensus spine — what a new hypothesis is
            // aligned against.
            let spine = slots.map { spinePlurality($0) }
            let ops = align(spine: spine, hypothesis: hypothesis)

            var merged: [[String: String]] = []
            var slotIdx = 0, hypIdx = 0
            for op in ops {
                switch op {
                case .match, .substitute:
                    var slot = slots[slotIdx]
                    slot[engine] = hypothesis[hypIdx]
                    merged.append(slot)
                    slotIdx += 1; hypIdx += 1
                case .deleteFromSpine:
                    // The network has a slot the hypothesis skipped — an
                    // explicit epsilon vote, never an absent key.
                    var slot = slots[slotIdx]
                    slot[engine] = ROVERAdjudicator.epsilon
                    merged.append(slot)
                    slotIdx += 1
                case .insertFromHypothesis:
                    // A slot no prior engine had: every earlier engine votes
                    // epsilon there.
                    var slot: [String: String] = [:]
                    for prior in engines.prefix(while: { $0 != engine }) {
                        slot[prior] = ROVERAdjudicator.epsilon
                    }
                    slot[engine] = hypothesis[hypIdx]
                    merged.append(slot)
                    hypIdx += 1
                }
            }
            slots = merged
        }

        // Any engine that never reached a slot (possible when a later insertion
        // shifted things) votes epsilon there — the network must be total.
        let complete = slots.map { slot -> ConfusionSlot in
            var full = slot
            for engine in engines where full[engine] == nil { full[engine] = ROVERAdjudicator.epsilon }
            return ConfusionSlot(alternatives: full)
        }
        return ConfusionNetwork(page: page, slots: complete)
    }

    private static func spinePlurality(_ slot: [String: String]) -> String {
        var tally: [String: Int] = [:]
        for token in slot.values where token != ROVERAdjudicator.epsilon {
            tally[token, default: 0] += 1
        }
        return tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key
            ?? ROVERAdjudicator.epsilon
    }

    private enum Op { case match, substitute, deleteFromSpine, insertFromHypothesis }

    /// Levenshtein backtrace over tokens, diagonal-preferred on ties so the
    /// alignment is deterministic.
    private static func align(spine: [String], hypothesis: [String]) -> [Op] {
        let n = spine.count, m = hypothesis.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let sub = dp[i - 1][j - 1] + (spine[i - 1] == hypothesis[j - 1] ? 0 : 1)
                    dp[i][j] = min(sub, min(dp[i - 1][j] + 1, dp[i][j - 1] + 1))
                }
            }
        }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               dp[i][j] == dp[i - 1][j - 1] + (spine[i - 1] == hypothesis[j - 1] ? 0 : 1) {
                ops.append(spine[i - 1] == hypothesis[j - 1] ? .match : .substitute)
                i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                ops.append(.deleteFromSpine); i -= 1
            } else {
                ops.append(.insertFromHypothesis); j -= 1
            }
        }
        return ops.reversed()
    }
}

/// Slot-wise plurality over a confusion network, `epsilon` included as a
/// candidate — an engine voting "nothing here" is a real vote, which is what
/// lets the combination *delete* a spurious insertion.
///
/// ## Its item is a token slot, not a line
///
/// Every other adjudicator's item is a line (or table cell). ROVER's is a
/// token, so its `low_consensus_share` is a share of **tokens**. That is a
/// genuinely different quantity, and the concrete reason the estimand name
/// carries the adjudicator id (#17 phase 0b).
///
/// ## Honest limits
///
/// - Network construction is order-dependent (sorted engine ids for
///   determinism), inherited from ROVER's incremental alignment.
/// - Whitespace tokenization cannot see intra-word confusions; `ds-full` is the
///   model for those.
/// - Correlated errors still inflate agreement (spec §8).
public struct ROVERAdjudicator: SequenceAdjudicator {
    public static let id = "rover"
    public static let epsilon = "␀"
    public static let guidance =
        "when engines disagree by INSERTING or DELETING text, not just by reading a line differently — its item is a token slot, so its low-consensus share counts tokens, not lines. Coarsest on intra-word errors; use ds-full for those."

    public init() {}

    public func adjudicate(network: ConfusionNetwork) -> ConsensusEstimate {
        let engines = Set(network.slots.flatMap { $0.alternatives.keys }).sorted()
        var verdicts: [ItemConsensus] = []
        var correct: [String: Int] = [:], answered: [String: Int] = [:]

        for (index, slot) in network.slots.enumerated() {
            var tally: [String: Int] = [:]
            for token in slot.alternatives.values { tally[token, default: 0] += 1 }
            let ranked = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            let top = ranked[0]
            let tied = ranked.count > 1 && ranked[1].value == top.value
            let total = slot.alternatives.count

            for (engine, token) in slot.alternatives {
                answered[engine, default: 0] += 1
                if token == top.key { correct[engine, default: 0] += 1 }
            }

            verdicts.append(ItemConsensus(
                key: ItemKey(page: network.page, index: index, kind: .other),
                consensusText: top.key,
                confidence: total > 0 ? Double(top.value) / Double(total) : 0,
                lowConsensus: tied || top.value < 2,
                responses: slot.alternatives))
        }

        // Slot-level agreement with the combined output, Laplace-smoothed —
        // the same shape as every other adjudicator's competence, measured over
        // slots rather than lines.
        var overall: [String: Double] = [:]
        for engine in engines {
            overall[engine] = Double((correct[engine] ?? 0) + 1) / Double((answered[engine] ?? 0) + 2)
        }

        return ConsensusEstimate(
            adjudicator: Self.id,
            items: verdicts,
            agreement: slotAgreement(network: network, engines: engines),
            diagnostics: AdjudicatorDiagnostics(overallCompetence: overall,
                                                competence: nil,   // no per-kind notion: every slot is .other
                                                iterations: nil,   // one-shot
                                                converged: nil,
                                                confusion: nil))
    }

    /// Pairwise slot agreement — the same correlated-error diagnostic every
    /// adjudicator reports, computed over slots.
    private func slotAgreement(network: ConfusionNetwork,
                               engines: [String]) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        for a in engines {
            for b in engines where a != b {
                var n = 0, agree = 0
                for slot in network.slots {
                    guard let ta = slot.alternatives[a], let tb = slot.alternatives[b] else { continue }
                    n += 1
                    if ta == tb { agree += 1 }
                }
                guard n > 0 else { continue }
                out[a, default: [:]][b] = Double(agree) / Double(n)
            }
        }
        return out
    }
}
