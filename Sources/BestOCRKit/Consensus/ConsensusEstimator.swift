import Foundation

/// Dawid-Skene-lite iterative consensus (#11).
///
/// Model: engines are informants; each aligned item is a categorical question
/// whose answer space is the distinct normalized responses observed on that
/// item. Iterate: competence-weighted plurality per item → per-kind Laplace
/// competence per engine → repeat until the consensus assignment is stable.
///
/// Honest limits (issue #11 Clarity resolutions + verify findings):
/// - Weights are the per-kind competence values themselves (monotone,
///   bounded by Laplace smoothing) — not log-odds; documented MVP choice.
/// - Uninformative items (top-weight tie, or winner corroborated by fewer
///   than two engines) never enter competence: a tie's lexicographic winner
///   would poison cold start, and a solo item's winner is trivially its own
///   response — crediting it lets a hallucinating engine outrank accurate
///   ones (verify #11 finding 2). The same items carry the `lowConsensus`
///   flag routing them to human review.
/// - Verdicts, per-kind competence, and overall competence are all derived
///   from the SAME terminal E-step assignment, so the report stays
///   internally consistent even when `maxIterations` interrupts EM
///   (verify #11 finding 3); `converged` says which case occurred.
/// - Inter-engine error correlation (shared failure modes) inflates
///   competence; the pairwise `agreement` matrix surfaces it as a diagnostic
///   and no correction is applied in the MVP.
public enum ConsensusEstimator {

    private static let defaultCompetence = 0.5
    private static let tieEpsilon = 1e-9

    public static func estimate(items allItems: [AlignedItem], maxIterations: Int = 20) -> ConsensusEstimate {
        // Empty-response items carry no signal and would trap weightedWinner
        // (public-API hardening — the pipeline never builds them).
        let items = allItems.filter { !$0.responses.isEmpty }
        guard !items.isEmpty else {
            return ConsensusEstimate(items: [], overallCompetence: [:], competence: [:],
                                     agreement: [:], iterations: 0, converged: true)
        }

        let engines = Set(items.flatMap { $0.responses.keys }).sorted()

        // competence[engine][kind], only for kinds the engine actually answered.
        var perKind: [String: [ItemKind: Double]] = [:]
        var assignment: [Int: String] = [:]
        var uninformative: Set<Int> = []
        var winners: [Int: Winner] = [:]
        var iterations = 0
        var converged = false

        for _ in 1...max(1, maxIterations) {
            iterations += 1
            var next: [Int: String] = [:]
            var nextUninformative: Set<Int> = []
            var nextWinners: [Int: Winner] = [:]
            for (idx, item) in items.enumerated() {
                let win = weightedWinner(item: item, perKind: perKind)
                next[idx] = win.text
                nextWinners[idx] = win
                let supporters = item.responses.values.filter { $0 == win.text }.count
                if win.topTie || supporters < 2 { nextUninformative.insert(idx) }
            }
            let stable = (next == assignment && nextUninformative == uninformative)
            assignment = next
            uninformative = nextUninformative
            winners = nextWinners
            if stable { converged = true; break }
            perKind = competences(items: items, consensus: assignment,
                                  excluding: uninformative, engines: engines)
        }

        // Terminal state: verdicts ARE the last E-step, and competences are
        // measured against that same assignment — consistent by construction.
        // At a fixed point this recompute equals the in-loop M-step exactly.
        perKind = competences(items: items, consensus: assignment,
                              excluding: uninformative, engines: engines)

        var verdicts: [ItemConsensus] = []
        for (idx, item) in items.enumerated() {
            let win = winners[idx]!
            verdicts.append(ItemConsensus(key: item.key,
                                          consensusText: win.text,
                                          confidence: win.share,
                                          lowConsensus: uninformative.contains(idx),
                                          responses: item.responses))
        }

        // Overall competence: pooled Laplace across kinds, uninformative
        // items excluded — the same rule as the M-step.
        var overall: [String: Double] = [:]
        for engine in engines {
            var n = 0, correct = 0
            for (idx, item) in items.enumerated() {
                guard !uninformative.contains(idx), let r = item.responses[engine] else { continue }
                n += 1
                if r == assignment[idx] { correct += 1 }
            }
            overall[engine] = Double(correct + 1) / Double(n + 2)
        }

        return ConsensusEstimate(items: verdicts,
                                 overallCompetence: overall,
                                 competence: perKind,
                                 agreement: agreementMatrix(items: items, engines: engines),
                                 iterations: iterations,
                                 converged: converged)
    }

    // MARK: - Internals

    private struct Winner { let text: String; let share: Double; let topTie: Bool }

    /// Competence-weighted plurality with deterministic lexicographic
    /// tie-break. Returns the winner, its weight share, and whether the top
    /// weight was tied (within epsilon).
    private static func weightedWinner(item: AlignedItem,
                                       perKind: [String: [ItemKind: Double]]) -> Winner {
        var tally: [String: Double] = [:]
        for (engine, response) in item.responses {
            let w = perKind[engine]?[item.key.kind] ?? defaultCompetence
            tally[response, default: 0] += w
        }
        // Deterministic order: weight desc, then text asc.
        let ranked = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let top = ranked[0]
        let total = tally.values.reduce(0, +)
        let topTie = ranked.count > 1 && abs(ranked[1].value - top.value) < tieEpsilon
        return Winner(text: top.key,
                      share: total > 0 ? top.value / total : 0,
                      topTie: topTie)
    }

    /// Per-kind Laplace competence: (correct + 1) / (n + 2) over the items of
    /// that kind the engine answered, excluding tie-resolved (uninformative)
    /// items. Kinds never answered get no entry.
    private static func competences(items: [AlignedItem], consensus: [Int: String],
                                    excluding tied: Set<Int>,
                                    engines: [String]) -> [String: [ItemKind: Double]] {
        var counts: [String: [ItemKind: (n: Int, correct: Int)]] = [:]
        for (idx, item) in items.enumerated() {
            guard !tied.contains(idx) else { continue }
            for (engine, response) in item.responses {
                var kindCounts = counts[engine] ?? [:]
                var c = kindCounts[item.key.kind] ?? (0, 0)
                c.n += 1
                if response == consensus[idx] { c.correct += 1 }
                kindCounts[item.key.kind] = c
                counts[engine] = kindCounts
            }
        }
        var out: [String: [ItemKind: Double]] = [:]
        for engine in engines {
            guard let kindCounts = counts[engine] else { continue }
            var m: [ItemKind: Double] = [:]
            for (kind, c) in kindCounts {
                m[kind] = Double(c.correct + 1) / Double(c.n + 2)
            }
            out[engine] = m
        }
        return out
    }

    /// Pairwise raw agreement over co-answered items — the independence
    /// diagnostic. Symmetric by construction; pairs with no co-answered
    /// items get no entry.
    private static func agreementMatrix(items: [AlignedItem],
                                        engines: [String]) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        for a in engines {
            for b in engines where a != b {
                var n = 0, agree = 0
                for item in items {
                    guard let ra = item.responses[a], let rb = item.responses[b] else { continue }
                    n += 1
                    if ra == rb { agree += 1 }
                }
                guard n > 0 else { continue }
                out[a, default: [:]][b] = Double(agree) / Double(n)
            }
        }
        return out
    }
}
