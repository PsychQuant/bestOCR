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

/// One aligned item: normalized responses keyed by engine id. An engine absent
/// from `responses` did not produce an alignable answer for this item.
public struct AlignedItem: Sendable {
    public let key: ItemKey
    public let responses: [String: String]

    public init(key: ItemKey, responses: [String: String]) {
        self.key = key
        self.responses = responses
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

    public init(items: [ItemConsensus], overallCompetence: [String: Double],
                competence: [String: [ItemKind: Double]],
                agreement: [String: [String: Double]], iterations: Int) {
        self.items = items
        self.overallCompetence = overallCompetence
        self.competence = competence
        self.agreement = agreement
        self.iterations = iterations
    }
}
