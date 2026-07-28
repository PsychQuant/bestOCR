import Foundation

/// #17 phase 3 — competence-**prior**-weighted vote.
///
/// ds-lite estimates competence from within-item agreement alone, which a
/// colluding pair can dominate: two engines sharing a failure mode outvote a
/// better one and then credit each other for it. This adjudicator instead takes
/// competence as a *fixed input* measured elsewhere — the benchmark rows this
/// product already maintains — closing the loop between the evidence base and
/// the consensus layer.
///
/// ## The prior is an input, not an estimate
///
/// It is reported in `AdjudicatorDiagnostics.priorCompetence`, **not** in
/// `overallCompetence`, which stays `nil`. Echoing a handed-in number back as
/// an estimated one would claim a measurement this model never performed —
/// exactly the mislabelling #17 exists to prevent.
///
/// ## Acyclicity (spec §10)
///
/// `fromEvidence` refuses rows the consensus layer itself produced. Without
/// that rule an engine's prior inflates its influence, which inflates its
/// measured agreement, which is promoted back into evidence and inflates the
/// prior. Rows must come from **single-engine** measurement, and only at T2 —
/// a vendor's T3 claim is not our measurement.
public struct PriorWeightedAdjudicator: ConsensusAdjudicator {
    public static let id = "prior-weighted"
    public static let guidance =
        "when you have measured word_recall rows and only 2 engines, where competence is "
        + "barely identifiable from agreement alone. Only as good as the benchmark behind "
        + "it, and it assumes 0.5 for anything unmeasured (disclosed in the report)." 

    /// Weight for an engine with no measured row. Deliberately mid-scale: an
    /// unmeasured engine must be neither trusted nor discarded, and the
    /// assumption has to be visible rather than silently favourable.
    public static let neutralPrior = 0.5

    /// Engine id → competence in (0, 1].
    public let prior: [String: Double]
    /// Engines running on `neutralPrior` because nothing measured them. Named
    /// so a report can say which weights were *assumed* rather than measured.
    public let assumedEngines: [String]

    public init(prior: [String: Double], assumedEngines: [String] = []) {
        self.prior = prior
        self.assumedEngines = assumedEngines
    }

    /// Builds a prior from measured quality rows.
    ///
    /// Admission rules, all of them load-bearing:
    /// 1. estimand is `quality.word_recall` (version-canonicalized, so legacy
    ///    unversioned rows still count — #16's `Estimand.canonical`);
    /// 2. tier is **T2** — our own measurement, never a vendor claim;
    /// 3. the row is **not** consensus-derived (acyclicity, spec §10);
    /// 4. the row's `condition.model` identifies one of the given engines.
    ///
    /// Multiple qualifying rows for one engine are averaged — a mean of
    /// same-estimand, same-tier rows, which is the one arithmetic
    /// `evidence/schema.md` hard rule 2 permits without a new formula name.
    public static func fromEvidence(_ store: EvidenceStore,
                                    engineIDs: [String]) -> PriorWeightedAdjudicator {
        let target = Estimand.canonical("quality.word_recall")
        var buckets: [String: [Double]] = [:]

        for row in store.rows {
            guard Estimand.canonical(row.estimand) == target, row.tier == "T2" else { continue }
            // Acyclicity: anything the consensus layer produced is disqualified
            // from seeding a prior for the consensus layer.
            guard row.condition.model != Self.consensusMarker,
                  row.condition.platform != Self.consensusMarker else { continue }
            guard let engine = matchEngine(model: row.condition.model, in: engineIDs) else { continue }
            buckets[engine, default: []].append(row.value)
        }

        var prior: [String: Double] = [:]
        var assumed: [String] = []
        for id in engineIDs {
            if let values = buckets[id], !values.isEmpty {
                prior[id] = values.reduce(0, +) / Double(values.count)
            } else {
                prior[id] = neutralPrior
                assumed.append(id)
            }
        }
        return PriorWeightedAdjudicator(prior: prior, assumedEngines: assumed.sorted())
    }

    /// The reserved runlog/condition marker for ensemble rows (`RunLog`).
    private static let consensusMarker = "consensus"

    /// Rows record a *model* (`glm-ocr`); the pipeline speaks *engine ids*
    /// (`vlm.glm-ocr`). Exact match first, then the `<family>.<model>` form —
    /// nothing fuzzier, because a wrong match silently reweights a vote.
    private static func matchEngine(model: String, in engineIDs: [String]) -> String? {
        if engineIDs.contains(model) { return model }
        return engineIDs.first { $0.hasSuffix(".\(model)") }
    }

    // MARK: - Adjudication

    public func adjudicate(items allItems: [AlignedItem]) -> ConsensusEstimate {
        let items = ConsensusShared.votable(allItems)
        let engines = ConsensusShared.realEngines(items)

        var verdicts: [ItemConsensus] = []
        for item in items {
            var tally: [String: Double] = [:]
            for (engine, response) in item.responses where !response.canonical.isEmpty {
                tally[response.canonical, default: 0] += prior[engine] ?? Self.neutralPrior
            }
            // Same deterministic ordering and same review rule as every other
            // adjudicator, so differences are differences of MODEL.
            let ranked = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            let top = ranked[0]
            let total = tally.values.reduce(0, +)
            let tied = ranked.count > 1 && abs(ranked[1].value - top.value) < 1e-9
            let supporters = item.responses.values.filter { $0.canonical == top.key }.count

            verdicts.append(ItemConsensus(
                key: item.key,
                consensusText: ConsensusShared.representative(item: item, label: top.key),
                confidence: total > 0 ? top.value / total : 0,
                lowConsensus: tied || supporters < 2,
                responses: item.responses.mapValues(\.raw)))
        }

        return ConsensusEstimate(
            adjudicator: Self.id,
            items: verdicts,
            agreement: ConsensusShared.agreementMatrix(items: items, engines: engines),
            diagnostics: AdjudicatorDiagnostics(
                // nil, emphatically: this model does not estimate competence.
                overallCompetence: nil,
                competence: nil,
                iterations: nil,      // one-shot; there is no EM to converge
                converged: nil,
                confusion: nil,
                priorCompetence: prior,
                assumedPriorEngines: assumedEngines.isEmpty ? nil : assumedEngines))
    }
}
