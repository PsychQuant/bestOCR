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
    public let index: Int      // position in the aligned spine, monotone per page
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

/// Full estimator output: per-item verdicts + per-engine competence
/// (overall and per item kind) + pairwise raw-agreement diagnostic.
public struct ConsensusEstimate: Sendable {
    public let items: [ItemConsensus]
    public let overallCompetence: [String: Double]
    public let competence: [String: [ItemKind: Double]]
    /// Pairwise raw agreement over co-answered items — independence-violation
    /// diagnostic (engines sharing errors inflate each other's competence).
    public let agreement: [String: [String: Double]]
    public let iterations: Int
    /// False when the iteration cap interrupted EM before the assignment and
    /// tie set stabilized — the verdicts are still internally consistent
    /// (competences are measured against them) but not a fixed point.
    public let converged: Bool

    public init(items: [ItemConsensus], overallCompetence: [String: Double],
                competence: [String: [ItemKind: Double]],
                agreement: [String: [String: Double]], iterations: Int,
                converged: Bool) {
        self.items = items
        self.overallCompetence = overallCompetence
        self.competence = competence
        self.agreement = agreement
        self.iterations = iterations
        self.converged = converged
    }
}
