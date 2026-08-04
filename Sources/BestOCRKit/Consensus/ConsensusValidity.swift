import Foundation

/// #39: CCT single-consensus validity check.
///
/// Every pooling estimator here (ds-lite, ds-full, prior-weighted, irt)
/// assumes all engines are noisy readings of ONE latent answer key. That
/// assumption has its own validity condition (Romney, Weller & Batchelder
/// 1986): a minimum-residual factor analysis of the rater×rater agreement
/// matrix must show (a) a dominant first factor — first-to-second eigenvalue
/// ratio ≥ 3 by CCT convention — and (b) all first-factor loadings positive.
/// Failing either means there is no single consensus to estimate: competence
/// is then not a weak estimate of engine quality, it is an estimate of a
/// quantity that does not exist for the run (#39).
///
/// Implementation notes, in decreasing order of surprise:
/// - The agreement matrix is non-negative, so by Perron-Frobenius the leading
///   eigenvector can be oriented non-negative — negative loadings cannot
///   occur here. The operative form of CCT's "all loadings positive" is
///   therefore "no ZERO loadings": a block partition puts the leading
///   eigenvector entirely on one block and zeros on the other. The two
///   conditions are complementary — equal-size blocks are caught by the
///   ratio (λ1 ≈ λ2), unequal ones by the zero loadings.
/// - Eigen decomposition is a hand-written cyclic Jacobi: unconditionally
///   convergent for symmetric matrices and fully unit-testable against
///   analytic spectra. Power iteration was rejected because it fails to
///   converge precisely when λ1 ≈ λ2 — the regime this check must measure.
/// - The minimum-residual diagonal treatment is the standard ONE-STEP
///   communality approximation (diagonal ← row max |off-diagonal|), not the
///   iterated fit — the gate needs the ratio's position relative to the
///   threshold, not precise loadings.
/// - The threshold 3 is the CCT literature convention, NOT calibrated on
///   this corpus (same evidence-pending discipline as the #38 co-answer
///   threshold). Override: `BESTOCR_CONSENSUS_MIN_EIGEN_RATIO`.
public enum ConsensusValidity {

    /// Outcome of the single-consensus check. `untestable` is disclosed to
    /// the caller and is NOT a pass — "could not test the assumption" and
    /// "tested and held" must never render the same.
    public enum Verdict: Equatable {
        case passed(ratio: Double, loadings: [String: Double])
        case failed(reason: String)
        case untestable(reason: String)
    }

    /// λ1/λ2 refusal threshold. A value ≤ 1 is meaningless (λ1 ≥ λ2 always),
    /// so like #38's `minCoAnswerThreshold` any unusable override falls back
    /// to the default rather than silently disabling the gate.
    public static func minEigenRatio(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        guard let raw = env["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO"], let v = Double(raw),
              v.isFinite, v > 1 else { return 3.0 }
        return v
    }

    /// The check, on the sparse agreement dictionary exactly as
    /// `ConsensusEstimator.agreementMatrix` produces it (pairs with no
    /// co-answered items have NO entry — that absence densifies to 0, which
    /// is precisely the cross-block signal the check looks for).
    ///
    /// Engines with no agreement entries at all are EXCLUDED, not failed:
    /// no co-answer data is absence of evidence, not evidence of a second
    /// culture (their competence already renders as "prior — no informative
    /// items" per #38). Exclusions are disclosed. Fewer than 3 included
    /// engines → `untestable` (two raters cannot distinguish one culture
    /// from two).
    public static func singleConsensusCheck(
        agreement: [String: [String: Double]],
        engines: [String],
        minRatio: Double
    ) -> (verdict: Verdict, excluded: [String]) {
        let included = engines.filter { !(agreement[$0] ?? [:]).isEmpty }.sorted()
        let excluded = engines.filter { (agreement[$0] ?? [:]).isEmpty }.sorted()
        guard included.count >= 3 else {
            return (.untestable(reason: "only \(included.count) engine(s) with "
                        + "co-answer data — the single-consensus check needs ≥ 3"),
                    excluded)
        }
        let dense = denseAgreement(from: agreement, engines: included)
        let eigen = jacobiEigen(dense)
        let lambda1 = eigen.values[0]
        guard lambda1 > 1e-9 else {
            return (.failed(reason: "single-consensus check failed: no agreement "
                        + "structure — engines co-answer but never agree (λ1 = 0); "
                        + "there is no shared answer key to estimate"),
                    excluded)
        }
        let ratio = lambda1 / max(eigen.values[1], 1e-12)
        var lead = eigen.vectors[0]
        if let maxIdx = lead.indices.max(by: { abs(lead[$0]) < abs(lead[$1]) }),
           lead[maxIdx] < 0 {
            lead = lead.map { -$0 }
        }
        var loadings: [String: Double] = [:]
        for (i, id) in included.enumerated() { loadings[id] = lead[i] }
        guard ratio >= minRatio else {
            return (.failed(reason: String(
                        format: "single-consensus check failed: eigenvalue ratio "
                            + "λ1/λ2 = %.2f < threshold %.1f — the agreement structure "
                            + "is consistent with more than one answer key, so "
                            + "per-engine competence is not defined for this run",
                        ratio, minRatio)),
                    excluded)
        }
        let outsiders = included.filter { (loadings[$0] ?? 0) <= 1e-9 }
        guard outsiders.isEmpty else {
            return (.failed(reason: "single-consensus check failed: engine(s) "
                        + outsiders.joined(separator: ", ")
                        + " have zero first-factor loading — they sit outside the "
                        + "leading consensus block (eigenvalue ratio "
                        + String(format: "%.2f", ratio) + ")"),
                    excluded)
        }
        return (.passed(ratio: ratio, loadings: loadings), excluded)
    }

    // MARK: - Internals

    /// Densify the sparse agreement dictionary over `engines` (row/column
    /// order): missing pair → 0. Diagonal ← row max |off-diagonal| (one-step
    /// minres communality approximation; see type doc).
    static func denseAgreement(from sparse: [String: [String: Double]],
                               engines: [String]) -> [[Double]] {
        let n = engines.count
        var m = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n where i != j {
                m[i][j] = sparse[engines[i]]?[engines[j]] ?? 0
            }
        }
        for i in 0..<n {
            var rowMax = 0.0
            for j in 0..<n where j != i { rowMax = max(rowMax, abs(m[i][j])) }
            m[i][i] = rowMax
        }
        return m
    }

    /// Cyclic Jacobi eigen decomposition for a small symmetric matrix.
    /// Returns eigenvalues in descending order with matching eigenvectors
    /// (each `vectors[k]` is the unit eigenvector for `values[k]`).
    static func jacobiEigen(_ matrix: [[Double]])
        -> (values: [Double], vectors: [[Double]]) {
        let n = matrix.count
        var a = matrix
        // Columns of v accumulate the eigenvectors.
        var v = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }
        for _ in 0..<100 {
            var offSquared = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n { offSquared += a[i][j] * a[i][j] }
            }
            if offSquared < 1e-24 { break }
            for p in 0..<n {
                for q in (p + 1)..<n {
                    let apq = a[p][q]
                    if abs(apq) < 1e-15 { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0)
                        / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    // A ← GᵀAG, applied as full column then row updates so the
                    // p/q cross elements go through both rotations.
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let order = (0..<n).sorted { a[$0][$0] > a[$1][$1] }
        return (order.map { a[$0][$0] },
                order.map { col in (0..<n).map { v[$0][col] } })
    }
}

/// #39: report-facing record of the single-consensus check. `nil` on a
/// report means the check did not run (pre-#39 report, majority, rover) —
/// absence is never a verdict.
public struct SingleConsensusCheck: Codable, Equatable, Sendable {
    /// "passed" / "failed" / "untestable".
    public let verdict: String
    /// λ1/λ2 — present on passed. A failed check carries its ratio inside
    /// `reason` (issue contract: "a refusal with the eigenvalue ratio in
    /// the message is enough").
    public let ratio: Double?
    /// First-factor loadings per included engine (passed only).
    public let loadings: [String: Double]?
    /// Engines excluded for having no co-answer data at all — absence of
    /// evidence, not evidence of a second culture.
    public let excludedEngines: [String]
    /// Explanation for failed / untestable verdicts.
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case verdict, ratio, loadings, reason
        case excludedEngines = "excluded_engines"
    }

    public init(verdict: ConsensusValidity.Verdict, excluded: [String]) {
        self.excludedEngines = excluded
        switch verdict {
        case .passed(let ratio, let loadings):
            self.verdict = "passed"
            self.ratio = ratio
            self.loadings = loadings
            self.reason = nil
        case .failed(let reason):
            self.verdict = "failed"
            self.ratio = nil
            self.loadings = nil
            self.reason = reason
        case .untestable(let reason):
            self.verdict = "untestable"
            self.ratio = nil
            self.loadings = nil
            self.reason = reason
        }
    }
}
