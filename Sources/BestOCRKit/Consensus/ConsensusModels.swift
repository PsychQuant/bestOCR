import Foundation

/// #11 — multi-model consensus (CCT/Dawid-Skene-lite). Item taxonomy follows
/// the issue's resolved decisions: line-primary with table cells split out.
public enum ItemKind: String, Sendable, Codable, CaseIterable {
    case proseLine = "prose_line"
    case tableCell = "table_cell"
    case math
    case other
}

/// Stable identity of one recognition unit within a document.
public struct ItemKey: Hashable, Sendable, Codable {
    public let page: Int
    public let index: Int      // reading-order position on the page (spine + interleaved solos)
    public let kind: ItemKind

    public init(page: Int, index: Int, kind: ItemKind) {
        self.page = page
        self.index = index
        self.kind = kind
    }
}

/// One engine's answer for one item (#13 F5): the raw rendering (published
/// in transcript/report), the whitespace-normalized form (matching), and the
/// cached canonical vote label (computed once — voting, supporters, and the
/// agreement matrix compare it repeatedly).
public struct ItemResponse: Sendable {
    public let raw: String
    public let normalized: String
    public let canonical: String

    public init(raw: String, normalized: String) {
        self.raw = raw
        self.normalized = normalized
        self.canonical = ItemExtractor.canonicalLabel(normalized)
    }
}

/// One aligned item: responses keyed by engine id. An engine absent from
/// `responses` did not produce an alignable answer for this item.
public struct AlignedItem: Sendable {
    public let key: ItemKey
    public let responses: [String: ItemResponse]

    public init(key: ItemKey, responses: [String: ItemResponse]) {
        self.key = key
        self.responses = responses
    }

    /// Convenience for fixtures and simple callers: raw == normalized.
    public init(key: ItemKey, responses: [String: String]) {
        self.init(key: key,
                  responses: responses.mapValues { ItemResponse(raw: $0, normalized: $0) })
    }
}

/// Consensus verdict for one item.
public struct ItemConsensus: Sendable, Codable {
    public let key: ItemKey
    public let consensusText: String
    /// Winning weight share among responding engines, in (0, 1].
    public let confidence: Double
    /// True when the verdict needs human review: top-weight tie, or fewer
    /// than two corroborating responses.
    public let lowConsensus: Bool
    public let responses: [String: String]

    public init(key: ItemKey, consensusText: String, confidence: Double,
                lowConsensus: Bool, responses: [String: String]) {
        self.key = key
        self.consensusText = consensusText
        self.confidence = confidence
        self.lowConsensus = lowConsensus
        self.responses = responses
    }
}

/// Per-item latent parameters (#17 phase 4 — IRT / Bayesian CCT). An array of
/// pairs rather than a dictionary keyed by `ItemKey`: Swift encodes a
/// non-String-keyed dictionary as a flat alternating array, which is unreadable
/// in a report artifact — the same reason `ConsensusReport` uses string keys
/// throughout.
public struct ItemParameterEntry: Sendable, Equatable, Codable {
    public let key: ItemKey
    /// Model-named parameters, e.g. `difficulty`, `discrimination`, `guessing`.
    public let parameters: [String: Double]

    public init(key: ItemKey, parameters: [String: Double]) {
        self.key = key
        self.parameters = parameters
    }
}

/// Model-specific output of one adjudicator, with the distinction the whole
/// design rests on (#17 §4.2):
///
/// - `nil` — **this adjudicator has no such notion** (naive majority has no
///   competence and is not iterative).
/// - empty collection — it *has* the notion and there was nothing to report
///   (every item was uninformative, so no engine earned a competence entry).
///
/// Collapsing the two is the bug this type exists to prevent: it is what makes
/// a majority report read like a degenerate Dawid-Skene one.
///
/// **Known extensibility cost** (§4.3): a closed set of optional fields, so an
/// adjudicator reporting a genuinely novel quantity needs a new field. Accepted
/// while the adjudicator set is enumerated; the honest trigger to revisit is
/// IRT (phase 4), the first model whose output has no analogue in the others.
public struct AdjudicatorDiagnostics: Sendable, Equatable {
    /// Pooled per-engine competence. `nil` when the model has no such concept.
    public let overallCompetence: [String: Double]?
    /// Per-engine, per-item-kind competence. `nil` when unsupported.
    public let competence: [String: [ItemKind: Double]]?
    /// `nil` for one-shot (non-iterative) adjudicators.
    public let iterations: Int?
    /// `nil` when convergence is undefined for this model.
    public let converged: Bool?
    /// Per-engine directional confusion — engine → true label → observed label
    /// → probability. `nil` for every model without a confusion concept; this
    /// is what ds-lite structurally cannot hold and full Dawid-Skene restores.
    public let confusion: [String: [String: [String: Double]]]?
    /// `nil` until an adjudicator estimates per-item latent parameters.
    public let itemParameters: [ItemParameterEntry]?

    public init(overallCompetence: [String: Double]? = nil,
                competence: [String: [ItemKind: Double]]? = nil,
                iterations: Int? = nil,
                converged: Bool? = nil,
                confusion: [String: [String: [String: Double]]]? = nil,
                itemParameters: [ItemParameterEntry]? = nil) {
        self.overallCompetence = overallCompetence
        self.competence = competence
        self.iterations = iterations
        self.converged = converged
        self.confusion = confusion
        self.itemParameters = itemParameters
    }
}

/// Adjudicator output (#17): which model produced it, the per-item verdicts,
/// the adjudicator-independent agreement diagnostic, and whatever
/// model-specific quantities that adjudicator actually has.
///
/// `adjudicator` is not decoration — the same quantity computed by two
/// different models is two different estimands (`evidence/schema.md` hard
/// rules 1/3), so identity has to travel with the result rather than being
/// reconstructed by whoever reads it.
public struct ConsensusEstimate: Sendable {
    /// The `ConsensusAdjudicator.id` that produced this estimate.
    public let adjudicator: String
    public let items: [ItemConsensus]
    /// Pairwise raw agreement over co-answered items — independence-violation
    /// diagnostic (engines sharing errors inflate each other's competence).
    /// Computed from raw responses, so it is adjudicator-independent and
    /// stays comparable across models.
    public let agreement: [String: [String: Double]]
    /// Model-specific output. `nil` fields mean "no such notion", empty
    /// collections mean "nothing to report" — see `AdjudicatorDiagnostics`.
    public let diagnostics: AdjudicatorDiagnostics

    public init(adjudicator: String, items: [ItemConsensus],
                agreement: [String: [String: Double]],
                diagnostics: AdjudicatorDiagnostics) {
        self.adjudicator = adjudicator
        self.items = items
        self.agreement = agreement
        self.diagnostics = diagnostics
    }
}
