import Foundation

/// #17 phase 4 — IRT adjudication (Rasch form).
///
/// Every other adjudicator here treats items as interchangeable: an engine that
/// gets an easy line right is credited exactly as much as one that gets a hard
/// line right. This model separates the two by estimating a per-engine
/// **ability** and a per-item **difficulty** jointly:
///
/// ```
/// P(engine e matches the truth on item i) = σ(θ_e − b_i)
/// ```
///
/// and votes with `σ(θ_e − b_i)` as the weight, so an engine's influence on a
/// hard item reflects what its ability predicts there rather than its average.
///
/// ## Identifiability — why difficulties are mean-centred
///
/// Rasch is additively indeterminate: `(θ + c, b + c)` produces an identical
/// likelihood for any `c`. Reported numbers would therefore be meaningful only
/// up to an unstated constant. The scale is anchored by centring `b` at zero on
/// every iteration, which makes `θ` interpretable as ability relative to an
/// average-difficulty item. This is a *convention*, chosen and stated, not a
/// property the data determines.
///
/// ## Honest limits
///
/// - **Estimation is a penalized point estimate**, not a posterior. Joint
///   maximum-likelihood for Rasch is known to be inconsistent as items grow
///   with a fixed number of raters; the ridge penalty keeps it stable, it does
///   not make it unbiased. Three OCR engines is a *very* small rater panel.
/// - Only difficulty is estimated. Discrimination (2PL) and guessing (3PL) are
///   deliberately not attempted: with this few raters they are not identifiable,
///   and fitting them anyway would produce numbers that look richer while
///   meaning less.
/// - **A Bayesian CCT / GCM variant is NOT provided.** It needs a sampler and a
///   real posterior; shipping a point estimate under the name "Bayesian" would
///   be exactly the mislabelling this issue exists to prevent. Recorded as
///   unbuilt rather than approximated.
/// - Correlated engine errors still inflate agreement (spec §8).
public struct IRTAdjudicator: ConsensusAdjudicator {
    public static let id = "irt"
    public static let guidance =
        "when items differ a lot in difficulty (mixed clean text and degraded scans) — it separates 'this engine is weak' from 'this line is hard', which no other adjudicator here does. Point estimates on a tiny rater panel: treat the numbers as ordering, not measurement."

    /// Ridge penalty. Without it a perfectly-separated engine or item drives its
    /// parameter to ±∞ — the standard Rasch separation problem.
    private static let ridge = 0.15
    private static let learningRate = 0.5
    private static let innerSteps = 40

    let maxIterations: Int
    public init(maxIterations: Int = 20) { self.maxIterations = maxIterations }

    public func adjudicate(items allItems: [AlignedItem]) -> ConsensusEstimate {
        let items = ConsensusShared.votable(allItems)
        let engines = ConsensusShared.realEngines(items)

        guard !items.isEmpty else {
            return ConsensusEstimate(
                adjudicator: Self.id, items: [], agreement: [:],
                diagnostics: AdjudicatorDiagnostics(overallCompetence: [:], competence: [:],
                                                    iterations: 0, converged: true,
                                                    confusion: nil, itemParameters: []))
        }

        var theta = Dictionary(uniqueKeysWithValues: engines.map { ($0, 0.0) })
        var difficulty = [Double](repeating: 0, count: items.count)
        var assignment = items.map { Self.plurality($0) }
        var iterations = 0
        var converged = false

        for _ in 1...max(1, maxIterations) {
            iterations += 1
            // M-step: fit (θ, b) to the current assignment.
            let responses = Self.responseMatrix(items: items, assignment: assignment)
            (theta, difficulty) = Self.fitRasch(responses: responses, engines: engines,
                                                itemCount: items.count)
            // E-step: re-vote with σ(θ_e − b_i) weights.
            var next: [String] = []
            for (idx, item) in items.enumerated() {
                next.append(Self.weightedWinner(item: item, theta: theta,
                                                difficulty: difficulty[idx]).label)
            }
            if next == assignment { converged = true; break }
            assignment = next
        }

        var verdicts: [ItemConsensus] = []
        var parameters: [ItemParameterEntry] = []
        for (idx, item) in items.enumerated() {
            let win = Self.weightedWinner(item: item, theta: theta, difficulty: difficulty[idx])
            let supporters = item.responses.values.filter { $0.canonical == win.label }.count
            verdicts.append(ItemConsensus(
                key: item.key,
                consensusText: ConsensusShared.representative(item: item, label: win.label),
                confidence: win.share,
                lowConsensus: win.tied || supporters < 2,
                responses: item.responses.mapValues(\.raw)))
            parameters.append(ItemParameterEntry(key: item.key,
                                                 parameters: ["difficulty": difficulty[idx]]))
        }

        // Ability reported on the probability scale — σ(θ_e), i.e. the chance of
        // matching the truth on an average-difficulty item (b = 0 by the
        // centring convention above). Same range as every other adjudicator's
        // competence, so the numbers are readable side by side; it is still a
        // DIFFERENT quantity, which is why the estimand name is qualified.
        let ability = theta.mapValues { 1.0 / (1.0 + exp(-$0)) }

        return ConsensusEstimate(
            adjudicator: Self.id,
            items: verdicts,
            agreement: ConsensusShared.agreementMatrix(items: items, engines: engines),
            diagnostics: AdjudicatorDiagnostics(overallCompetence: ability,
                                                competence: nil,   // no per-kind decomposition
                                                iterations: iterations,
                                                converged: converged,
                                                confusion: nil,    // no confusion model
                                                itemParameters: parameters))
    }

    // MARK: - Rasch fit

    /// `responses[engine][item]` = 1 when the engine matched the assigned
    /// truth, 0 when it answered and did not, `nil` when it abstained.
    private static func responseMatrix(items: [AlignedItem],
                                       assignment: [String]) -> [String: [Int?]] {
        var out: [String: [Int?]] = [:]
        for (idx, item) in items.enumerated() {
            for (engine, response) in item.responses {
                var row = out[engine] ?? [Int?](repeating: nil, count: items.count)
                if !response.canonical.isEmpty {
                    row[idx] = response.canonical == assignment[idx] ? 1 : 0
                }
                out[engine] = row
            }
        }
        return out
    }

    /// Ridge-penalized joint maximum likelihood by gradient ascent, with `b`
    /// mean-centred each step to anchor the additive indeterminacy.
    private static func fitRasch(responses: [String: [Int?]], engines: [String],
                                 itemCount: Int) -> ([String: Double], [Double]) {
        var theta = Dictionary(uniqueKeysWithValues: engines.map { ($0, 0.0) })
        var b = [Double](repeating: 0, count: itemCount)

        for _ in 0..<innerSteps {
            var gTheta = Dictionary(uniqueKeysWithValues: engines.map { ($0, 0.0) })
            var gB = [Double](repeating: 0, count: itemCount)

            for engine in engines {
                guard let row = responses[engine] else { continue }
                for (idx, value) in row.enumerated() {
                    guard let x = value else { continue }
                    let p = 1.0 / (1.0 + exp(-(theta[engine]! - b[idx])))
                    let residual = Double(x) - p
                    gTheta[engine]! += residual
                    gB[idx] -= residual
                }
            }
            for engine in engines { gTheta[engine]! -= ridge * theta[engine]! }
            for idx in 0..<itemCount { gB[idx] -= ridge * b[idx] }

            for engine in engines { theta[engine]! += learningRate * gTheta[engine]! / Double(max(itemCount, 1)) }
            for idx in 0..<itemCount { b[idx] += learningRate * gB[idx] / Double(max(engines.count, 1)) }

            // Anchor: mean difficulty = 0. Without this, (θ + c, b + c) drifts
            // and the published numbers mean nothing absolute.
            let mean = b.reduce(0, +) / Double(max(itemCount, 1))
            for idx in 0..<itemCount { b[idx] -= mean }
        }
        return (theta, b)
    }

    // MARK: - Voting

    private struct Winner { let label: String; let share: Double; let tied: Bool }

    private static func weightedWinner(item: AlignedItem, theta: [String: Double],
                                       difficulty: Double) -> Winner {
        var tally: [String: Double] = [:]
        for (engine, response) in item.responses where !response.canonical.isEmpty {
            let ability = theta[engine] ?? 0
            tally[response.canonical, default: 0] += 1.0 / (1.0 + exp(-(ability - difficulty)))
        }
        guard !tally.isEmpty else { return Winner(label: "", share: 0, tied: false) }
        let ranked = tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let top = ranked[0]
        let total = tally.values.reduce(0, +)
        return Winner(label: top.key,
                      share: total > 0 ? top.value / total : 0,
                      tied: ranked.count > 1 && abs(ranked[1].value - top.value) < 1e-9)
    }

    private static func plurality(_ item: AlignedItem) -> String {
        var tally: [String: Int] = [:]
        for response in item.responses.values where !response.canonical.isEmpty {
            tally[response.canonical, default: 0] += 1
        }
        return tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key ?? ""
    }
}
