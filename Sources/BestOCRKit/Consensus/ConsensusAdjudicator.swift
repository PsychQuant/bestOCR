import Foundation

/// #17 — the adjudicator is a pluggable choice, not a hard-wired one.
///
/// The injection point was never the hard part: `ConsensusPipeline.adjudicate`
/// called one estimator in one line. The hard part was that `ConsensusEstimate`
/// was a *Dawid-Skene-shaped* return type, so no other model could report
/// through it honestly — a naive-majority run returning empty competence maps
/// is indistinguishable from a Dawid-Skene run where nobody qualified.
///
/// Design spec: `docs/superpowers/specs/2026-07-28-pluggable-consensus-adjudicators.md`.
public protocol ConsensusAdjudicator: Sendable {
    /// Stable id. Enters the estimand name (`Estimand.consensus`) and the
    /// report, so a consensus number can never be read without knowing which
    /// model produced it.
    static var id: String { get }
    func adjudicate(items: [AlignedItem]) -> ConsensusEstimate
}

public extension ConsensusAdjudicator {
    var id: String { Self.id }
}

/// Naive majority — the **control**, not a formality.
///
/// Unweighted plurality over canonical vote labels. It exists so the CCT
/// family's benefit can be *measured* rather than asserted: if competence
/// weighting never beats plain plurality on real corpora, that is a finding
/// worth reporting, not a test to weaken.
///
/// Its low-consensus rule is deliberately identical to Dawid-Skene-lite's
/// (top-count tie, or fewer than two corroborating responses) so the two
/// models' `low_consensus_share` differ only by the adjudication itself.
public struct MajorityAdjudicator: ConsensusAdjudicator {
    public static let id = "majority"
    public init() {}

    public func adjudicate(items allItems: [AlignedItem]) -> ConsensusEstimate {
        // Same abstention rule as ds-lite: positional placeholders (empty
        // canonical, e.g. empty table cells) hold their alignment slot but
        // never vote.
        let items = allItems.filter { $0.responses.values.contains { !$0.canonical.isEmpty } }
        let engines = Set(items.flatMap { item in
            item.responses.filter { !$0.value.canonical.isEmpty }.map(\.key)
        }).sorted()

        var verdicts: [ItemConsensus] = []
        for item in items {
            var tally: [String: Int] = [:]
            for response in item.responses.values where !response.canonical.isEmpty {
                tally[response.canonical, default: 0] += 1
            }
            // Deterministic: count desc, then label asc.
            let ranked = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            let top = ranked[0]
            let total = tally.values.reduce(0, +)
            let topTie = ranked.count > 1 && ranked[1].value == top.value
            let representative = item.responses.values
                .filter { $0.canonical == top.key }.map(\.raw)
                .min { $0.utf8.lexicographicallyPrecedes($1.utf8) } ?? top.key

            verdicts.append(ItemConsensus(
                key: item.key,
                consensusText: representative,
                confidence: total > 0 ? Double(top.value) / Double(total) : 0,
                lowConsensus: topTie || top.value < 2,
                responses: item.responses.mapValues(\.raw)))
        }

        return ConsensusEstimate(
            adjudicator: Self.id,
            items: verdicts,
            // Raw-response diagnostic — adjudicator-independent by construction,
            // so it stays comparable across every model.
            agreement: ConsensusEstimator.agreementMatrix(items: items, engines: engines),
            // Every field nil: majority has no competence, no iteration, no
            // convergence, no confusion model. This is the point.
            diagnostics: AdjudicatorDiagnostics())
    }
}

/// Dawid-Skene-lite, reached through the protocol. The algorithm is unchanged —
/// `ConsensusEstimator` still owns it — so the migration cannot alter what this
/// model computes.
public struct DawidSkeneLiteAdjudicator: ConsensusAdjudicator {
    public static let id = "ds-lite"
    public let maxIterations: Int

    public init(maxIterations: Int = 20) { self.maxIterations = maxIterations }

    public func adjudicate(items: [AlignedItem]) -> ConsensusEstimate {
        ConsensusEstimator.estimate(items: items, maxIterations: maxIterations)
    }
}

/// What the CLI / MCP selection binds to. Ids are the user-facing values.
public enum AdjudicatorRegistry {
    /// Registration order is the display order; `ds-lite` stays first because
    /// it is the default and changing that silently would change every
    /// consensus artifact's meaning.
    public static let allIDs: [String] = [DawidSkeneLiteAdjudicator.id, MajorityAdjudicator.id]

    /// `nil` for an unknown id — callers MUST surface that rather than falling
    /// back to a default, or a typo would silently run a different model and
    /// label its output with the estimand of the one the user asked for.
    public static func make(_ id: String) -> (any ConsensusAdjudicator)? {
        switch id {
        case DawidSkeneLiteAdjudicator.id: return DawidSkeneLiteAdjudicator()
        case MajorityAdjudicator.id:       return MajorityAdjudicator()
        default:                           return nil
        }
    }

    /// The default preserves pre-#17 behaviour exactly.
    public static var `default`: any ConsensusAdjudicator { DawidSkeneLiteAdjudicator() }
}
