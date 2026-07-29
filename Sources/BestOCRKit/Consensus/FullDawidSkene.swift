import Foundation

/// #17 phase 2 — full Dawid-Skene with a per-engine **directional** confusion
/// model.
///
/// Restoring directional error rates is the entire point of "full vs lite":
/// ds-lite scores an engine with one scalar per item kind, so it can see *that*
/// an engine errs but never *how*. A systematic `0`→`O` reader and a random
/// guesser with the same error rate are indistinguishable to it.
///
/// ## Why the confusion is over CHARACTERS, not items
///
/// Textbook Dawid-Skene assumes a fixed set of K categories shared across
/// items, and estimates a K×K matrix per rater. OCR lines have no such set:
/// each item's answer space is whatever strings the engines happened to
/// produce there, so a confusion matrix over *item labels* would have every
/// category appear exactly once and estimate nothing.
///
/// The shared alphabet is at the character level, which is also where the
/// errors the model is supposed to catch actually live. So this estimates
/// `π_e(observed_char | true_char)` over the observed alphabet plus a
/// deletion/insertion symbol (`epsilon`), and scores a candidate label by
/// aligning each engine's response against it.
///
/// ## Model
///
/// - Answer space per item = the distinct real canonical responses observed on
///   that item (open vocabulary, same as ds-lite).
/// - **E-step**: assign each item the label maximizing `Σ_e log π_e(response_e | label)`.
///   Deterministic tie-break (score desc, then label asc); a tie is flagged.
/// - **M-step**: re-estimate `π_e` from the aligned `(true, observed)` character
///   pairs implied by the current assignment, Laplace-smoothed with one
///   reserved slot per row so an unseen observation keeps non-zero mass.
/// - Hard EM, deliberately matching ds-lite's inference style, so the two
///   adjudicators differ by **model** rather than by inference machinery.
///
/// ## Honest limits
///
/// - **Unigram characters cannot represent a merge.** The motivating examples
///   `0`↔`O` and `l`↔`1` are 1:1 substitutions and are captured. `rn`→`m` is
///   2:1 and is **not** — alignment decomposes it into `r`→`m` plus `n`→ε,
///   which is a decomposition, not a faithful model of the error. Capturing it
///   properly needs a bigram (or segment) confusion; that is a larger model and
///   is not attempted here.
/// - Alignment is an edit-distance backtrace, which is not unique. Ties resolve
///   diagonal-first so the result is deterministic, not because the diagonal is
///   more likely.
/// - Confusion counts are thin on short documents. Laplace smoothing keeps them
///   **proper**, not informative.
/// - Correlated engine errors still inflate each other (spec §8): the
///   `agreement` matrix stays a diagnostic, never a correction. A richer model
///   is not a correlation fix.
public struct FullDawidSkeneAdjudicator: ConsensusAdjudicator {
    public static let id = "ds-full"
    public static let guidance =
        "when errors are SYSTEMATIC (0/O, l/1) rather than random — it models direction, "
        + "which ds-lite structurally cannot. Needs enough text for the character counts to "
        + "mean anything; cannot represent multi-character merges like rn->m." 

    /// Deletion / insertion symbol in the confusion matrix. Visible on purpose:
    /// a report reader should be able to see that an engine drops characters,
    /// which is a different failure from substituting them.
    public static let epsilon = "ε"

    /// Laplace pseudo-count per (engine, true-char) row.
    private static let alpha = 0.5
    /// Alignment is O(n·m); beyond this length a pair is compared whole rather
    /// than aligned. Documented rather than silent — long items contribute
    /// coarse evidence instead of dominating the runtime.
    private static let maxAlignLength = 400
    private static let tieEpsilon = 1e-9

    let maxIterations: Int

    public init(maxIterations: Int = 20) { self.maxIterations = maxIterations }

    // MARK: - Adjudication

    public func adjudicate(items allItems: [AlignedItem]) -> ConsensusEstimate {
        let items = ConsensusShared.votable(allItems)
        let engines = ConsensusShared.realEngines(items)

        guard !items.isEmpty else {
            return ConsensusEstimate(
                adjudicator: Self.id, items: [], agreement: [:],
                // Empty, not nil: ds-full HAS a confusion concept and there was
                // simply nothing to estimate it from (#17 §4.2).
                diagnostics: AdjudicatorDiagnostics(overallCompetence: [:], competence: [:],
                                                    iterations: 0, converged: true,
                                                    confusion: [:]))
        }

        // Cold start: unweighted plurality. Deterministic (count desc, label
        // asc) and identical to what `MajorityAdjudicator` would produce, so
        // the EM path starts from the control rather than from a prior nobody
        // can inspect.
        var assignment: [Int: String] = [:]
        for (idx, item) in items.enumerated() { assignment[idx] = Self.plurality(item) }

        var confusion: [String: [String: [String: Double]]] = [:]
        var iterations = 0
        var converged = false

        for _ in 1...max(1, maxIterations) {
            iterations += 1
            confusion = Self.estimateConfusion(items: items, assignment: assignment)
            var next: [Int: String] = [:]
            for (idx, item) in items.enumerated() {
                next[idx] = Self.bestLabel(item: item, confusion: confusion).label
            }
            if next == assignment { converged = true; break }
            assignment = next
        }
        // Published confusion must be measured against the published
        // assignment, or the report contradicts itself.
        confusion = Self.estimateConfusion(items: items, assignment: assignment)

        var verdicts: [ItemConsensus] = []
        var uninformative: Set<Int> = []
        for (idx, item) in items.enumerated() {
            let scored = Self.bestLabel(item: item, confusion: confusion)
            let supporters = item.responses.values.filter { $0.canonical == scored.label }.count
            let low = scored.tied || supporters < 2
            if low { uninformative.insert(idx) }
            verdicts.append(ItemConsensus(
                key: item.key,
                consensusText: ConsensusShared.representative(item: item, label: scored.label),
                confidence: scored.posterior,
                lowConsensus: low,
                responses: item.responses.mapValues(\.raw)))
        }

        // Exact-match Laplace competence, same rule and same exclusions as
        // ds-lite — reported alongside the confusion so the two adjudicators
        // stay comparable on the quantity they share.
        let (overall, perKind) = Self.competences(items: items, assignment: assignment,
                                                  excluding: uninformative, engines: engines)

        return ConsensusEstimate(
            adjudicator: Self.id,
            items: verdicts,
            agreement: ConsensusShared.agreementMatrix(items: items, engines: engines),
            diagnostics: AdjudicatorDiagnostics(overallCompetence: overall,
                                                competence: perKind,
                                                iterations: iterations,
                                                converged: converged,
                                                confusion: confusion))
    }

    // MARK: - E-step

    private struct Scored { let label: String; let posterior: Double; let tied: Bool }

    /// Highest-likelihood label under the current confusion model, with its
    /// posterior share (log-sum-exp normalized over the item's answer space).
    private static func bestLabel(item: AlignedItem,
                                  confusion: [String: [String: [String: Double]]]) -> Scored {
        let candidates = Set(item.responses.values.map(\.canonical).filter { !$0.isEmpty }).sorted()
        guard !candidates.isEmpty else { return Scored(label: "", posterior: 0, tied: false) }

        var scores: [(label: String, logL: Double)] = []
        for candidate in candidates {
            var total = 0.0
            for (engine, response) in item.responses where !response.canonical.isEmpty {
                total += logLikelihood(observed: response.canonical, given: candidate,
                                       row: confusion[engine] ?? [:])
            }
            scores.append((candidate, total))
        }
        // Deterministic: log-likelihood desc, then label asc.
        scores.sort { ($0.logL, $1.label) > ($1.logL, $0.label) }
        let top = scores[0]
        let tied = scores.count > 1 && abs(scores[1].logL - top.logL) < tieEpsilon

        // Posterior over the item's answer space, computed stably.
        let maxLog = top.logL
        let denom = scores.reduce(0.0) { $0 + exp($1.logL - maxLog) }
        return Scored(label: top.label,
                      posterior: denom > 0 ? 1.0 / denom : 0,
                      tied: tied)
    }

    private static func logLikelihood(observed: String, given truth: String,
                                      row: [String: [String: Double]]) -> Double {
        var total = 0.0
        for pair in align(truth: truth, observed: observed) {
            let dist = row[pair.trueChar] ?? [:]
            // Unseen (engine, true-char) rows fall back to a weak
            // identity-favouring prior, so a first-iteration engine is not
            // scored as if every reading were equally plausible.
            let p = dist[pair.observed] ?? (pair.trueChar == pair.observed ? 0.5 : 1e-3)
            total += log(max(p, 1e-12))
        }
        return total
    }

    // MARK: - M-step

    private static func estimateConfusion(items: [AlignedItem],
                                          assignment: [Int: String])
        -> [String: [String: [String: Double]]] {
        var counts: [String: [String: [String: Double]]] = [:]
        for (idx, item) in items.enumerated() {
            guard let truth = assignment[idx], !truth.isEmpty else { continue }
            for (engine, response) in item.responses where !response.canonical.isEmpty {
                for pair in align(truth: truth, observed: response.canonical) {
                    counts[engine, default: [:]][pair.trueChar, default: [:]][pair.observed,
                                                                             default: 0] += 1
                }
            }
        }
        // Row-normalize with Laplace + one reserved slot for unseen observations.
        var out: [String: [String: [String: Double]]] = [:]
        for (engine, rows) in counts {
            var engineRows: [String: [String: Double]] = [:]
            for (trueChar, observations) in rows {
                let support = Double(observations.count) + 1   // +1 reserved unseen slot
                let denom = observations.values.reduce(0, +) + alpha * support
                guard denom > 0 else { continue }
                engineRows[trueChar] = observations.mapValues { ($0 + alpha) / denom }
            }
            out[engine] = engineRows
        }
        return out
    }

    // MARK: - Competence (shared quantity with ds-lite)

    private static func competences(items: [AlignedItem], assignment: [Int: String],
                                    excluding uninformative: Set<Int>, engines: [String])
        -> ([String: Double], [String: [ItemKind: Double]]) {
        var overall: [String: Double] = [:]
        var counts: [String: [ItemKind: (n: Int, correct: Int)]] = [:]
        for engine in engines {
            var n = 0, correct = 0
            for (idx, item) in items.enumerated() {
                guard !uninformative.contains(idx), let r = item.responses[engine],
                      !r.canonical.isEmpty else { continue }
                n += 1
                let hit = r.canonical == assignment[idx]
                if hit { correct += 1 }
                var byKind = counts[engine] ?? [:]
                var c = byKind[item.key.kind] ?? (0, 0)
                c.n += 1; if hit { c.correct += 1 }
                byKind[item.key.kind] = c
                counts[engine] = byKind
            }
            overall[engine] = Double(correct + 1) / Double(n + 2)
        }
        var perKind: [String: [ItemKind: Double]] = [:]
        for (engine, byKind) in counts {
            perKind[engine] = byKind.mapValues { Double($0.correct + 1) / Double($0.n + 2) }
        }
        return (overall, perKind)
    }

    // MARK: - Alignment

    /// One aligned position. `epsilon` on either side is an indel.
    struct CharPair: Equatable { let trueChar: String; let observed: String }

    /// Exposed for tests — indel representation is what makes the character
    /// model possible, so it is verified directly rather than inferred from
    /// estimator output.
    static func alignForTesting(truth: String, observed: String) -> [CharPair] {
        align(truth: truth, observed: observed)
    }

    /// Levenshtein backtrace, diagonal-preferred on ties so the result is
    /// deterministic. Over `maxAlignLength` the strings are compared whole
    /// (one coarse pair) rather than aligned — bounded cost, disclosed.
    private static func align(truth: String, observed: String) -> [CharPair] {
        let t = Array(truth), o = Array(observed)
        guard t.count <= maxAlignLength, o.count <= maxAlignLength else {
            return [CharPair(trueChar: truth == observed ? "=" : "≠",
                             observed: truth == observed ? "=" : "≠")]
        }
        if t.isEmpty && o.isEmpty { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: o.count + 1), count: t.count + 1)
        for i in 0...t.count { dp[i][0] = i }
        for j in 0...o.count { dp[0][j] = j }
        if t.count > 0 && o.count > 0 {
            for i in 1...t.count {
                for j in 1...o.count {
                    let sub = dp[i - 1][j - 1] + (t[i - 1] == o[j - 1] ? 0 : 1)
                    dp[i][j] = min(sub, min(dp[i - 1][j] + 1, dp[i][j - 1] + 1))
                }
            }
        }

        var pairs: [CharPair] = []
        var i = t.count, j = o.count
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               dp[i][j] == dp[i - 1][j - 1] + (t[i - 1] == o[j - 1] ? 0 : 1) {
                pairs.append(CharPair(trueChar: String(t[i - 1]), observed: String(o[j - 1])))
                i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                pairs.append(CharPair(trueChar: String(t[i - 1]), observed: epsilon))
                i -= 1
            } else {
                pairs.append(CharPair(trueChar: epsilon, observed: String(o[j - 1])))
                j -= 1
            }
        }
        return pairs.reversed()
    }

    // MARK: - Cold start

    private static func plurality(_ item: AlignedItem) -> String {
        var tally: [String: Int] = [:]
        for response in item.responses.values where !response.canonical.isEmpty {
            tally[response.canonical, default: 0] += 1
        }
        return tally.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key ?? ""
    }
}
