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
    /// One line on when this model fits — surfaced by
    /// `bestocr consensus --list-adjudicators` (#17 phase 6). Deliberately a
    /// tradeoff sentence, never a rank: these models estimate different things,
    /// so "best" is not a property any of them has.
    static var guidance: String { get }
    func adjudicate(items: [AlignedItem]) -> ConsensusEstimate
}

public extension ConsensusAdjudicator {
    var id: String { Self.id }
}

/// Plumbing every adjudicator shares — in one place so that verdict
/// differences between adjudicators can only come from their **models**, never
/// from divergent filtering / representative / diagnostic conventions.
enum ConsensusShared {
    /// Items with at least one REAL response. Positional placeholders (empty
    /// canonical, e.g. empty table cells) keep their alignment slot but never
    /// vote (#13).
    static func votable(_ items: [AlignedItem]) -> [AlignedItem] {
        items.filter { $0.responses.values.contains { !$0.canonical.isEmpty } }
    }

    /// Engines with at least one real response — an engine that only ever
    /// produced placeholders must not appear in diagnostics with prior-only
    /// values (#13).
    static func realEngines(_ items: [AlignedItem]) -> [String] {
        Set(items.flatMap { item in
            item.responses.filter { !$0.value.canonical.isEmpty }.map(\.key)
        }).sorted()
    }

    /// Deterministic raw representative of a winning canonical label.
    static func representative(item: AlignedItem, label: String) -> String {
        item.responses.values
            .filter { $0.canonical == label }.map(\.raw)
            .min { $0.utf8.lexicographicallyPrecedes($1.utf8) } ?? label
    }

    /// Pairwise raw agreement over co-answered items. Adjudicator-independent
    /// by construction (raw responses only), so it stays comparable across
    /// models — and it stays what it is: a correlated-error DIAGNOSTIC, never
    /// a correction (#17 §8).
    static func agreementMatrix(items: [AlignedItem],
                                engines: [String]) -> [String: [String: Double]] {
        ConsensusEstimator.agreementMatrix(items: items, engines: engines)
    }
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
    public static let guidance =
        "control / baseline. No competence, no assumptions. Use it to check whether "
        + "the competence-weighted models actually earn their complexity on your corpus." 
    public init() {}

    public func adjudicate(items allItems: [AlignedItem]) -> ConsensusEstimate {
        // Same abstention rule as ds-lite: positional placeholders (empty
        // canonical, e.g. empty table cells) hold their alignment slot but
        // never vote.
        let items = ConsensusShared.votable(allItems)
        let engines = ConsensusShared.realEngines(items)

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
            verdicts.append(ItemConsensus(
                key: item.key,
                consensusText: ConsensusShared.representative(item: item, label: top.key),
                confidence: total > 0 ? Double(top.value) / Double(total) : 0,
                lowConsensus: topTie || top.value < 2,
                responses: item.responses.mapValues(\.raw)))
        }

        return ConsensusEstimate(
            adjudicator: Self.id,
            items: verdicts,
            // Raw-response diagnostic — adjudicator-independent by construction,
            // so it stays comparable across every model.
            agreement: ConsensusShared.agreementMatrix(items: items, engines: engines),
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
    public static let guidance =
        "default. Competence estimated from within-item agreement; good with 3+ engines "
        + "that fail independently. Blind to HOW an engine errs, and a colluding pair can "
        + "dominate it." 
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
    public static let allIDs: [String] = [DawidSkeneLiteAdjudicator.id,
                                          MajorityAdjudicator.id,
                                          FullDawidSkeneAdjudicator.id,
                                          PriorWeightedAdjudicator.id,
                                          IRTAdjudicator.id,
                                          ROVERAdjudicator.id]

    /// `nil` for an unknown id — callers MUST surface that rather than falling
    /// back to a default, or a typo would silently run a different model and
    /// label its output with the estimand of the one the user asked for.
    public static func make(_ id: String) -> (any ConsensusAdjudicator)? {
        switch id {
        case DawidSkeneLiteAdjudicator.id: return DawidSkeneLiteAdjudicator()
        case MajorityAdjudicator.id:       return MajorityAdjudicator()
        case FullDawidSkeneAdjudicator.id: return FullDawidSkeneAdjudicator()
        // Built with a neutral prior; `ConsensusPipeline` replaces it with an
        // evidence-derived one when a store is available (phase 3).
        case PriorWeightedAdjudicator.id:  return PriorWeightedAdjudicator(prior: [:])
        case IRTAdjudicator.id:            return IRTAdjudicator()
        default:                           return nil
        }
    }

    /// The default preserves pre-#17 behaviour exactly.
    public static var `default`: any ConsensusAdjudicator { DawidSkeneLiteAdjudicator() }

    /// ROVER adjudicates a `ConfusionNetwork`, not `[AlignedItem]` — the
    /// pipeline must build a different input for it. Callers ask here rather
    /// than string-matching the id at each site.
    public static func isSequenceAdjudicator(_ id: String) -> Bool {
        id == ROVERAdjudicator.id
    }

    /// Sequence adjudicators resolve here, not through `make` — they are a
    /// different protocol because they consume a different input, and a
    /// registry that erased that would be lying about the contract.
    /// `nil` for an item adjudicator, symmetrically with `make`.
    public static func makeSequence(_ id: String) -> (any SequenceAdjudicator)? {
        id == ROVERAdjudicator.id ? ROVERAdjudicator() : nil
    }

    /// True when the id names something this registry can build at all —
    /// the invariant `allIDs` actually promises.
    public static func isKnown(_ id: String) -> Bool {
        make(id) != nil || makeSequence(id) != nil
    }

    /// #39: does this adjudicator POOL RATERS under a single latent answer
    /// key? That — the issue's own criterion — is what the single-consensus
    /// check guards, NOT "estimates competence": `prior-weighted` pools but
    /// deliberately reports no per-engine competence, and it still carries
    /// the single-key assumption (the old name mislabeled it — R1 rename).
    /// `majority` claims no competence model (no assumption to violate —
    /// issue Non-Goal). `rover` DOES report competence but its
    /// confusion-network alignment is outside the check's current wiring —
    /// a KNOWN gap, disclosed at the render layer and tracked in #49;
    /// adding it here alone would be a no-op (the sequence branch never
    /// calls the gate).
    public static func poolsRaters(_ id: String) -> Bool {
        [DawidSkeneLiteAdjudicator.id,
         FullDawidSkeneAdjudicator.id,
         PriorWeightedAdjudicator.id,
         IRTAdjudicator.id].contains(id)
    }

    /// `(id, guidance)` for every adjudicator, in display order. Phase 6: the
    /// selection surface states tradeoffs and never ranks — a single ordering
    /// would imply these models measure the same thing, which is exactly the
    /// claim #17 exists to refuse.
    public static var catalogue: [(id: String, guidance: String)] {
        [(DawidSkeneLiteAdjudicator.id, DawidSkeneLiteAdjudicator.guidance),
         (MajorityAdjudicator.id, MajorityAdjudicator.guidance),
         (FullDawidSkeneAdjudicator.id, FullDawidSkeneAdjudicator.guidance),
         (PriorWeightedAdjudicator.id, PriorWeightedAdjudicator.guidance),
         (IRTAdjudicator.id, IRTAdjudicator.guidance),
         (ROVERAdjudicator.id, ROVERAdjudicator.guidance)]
    }
}
