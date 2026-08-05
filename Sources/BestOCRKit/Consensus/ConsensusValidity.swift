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
/// - The agreement matrix is non-negative. The "no negative loadings"
///   guarantee is NOT Perron-Frobenius alone — PF only promises a
///   non-negative leading eigenvector EXISTS; with a degenerate λ1 the
///   returned basis vector could mix signs. What actually carries the
///   guarantee is the BRANCH ORDER: the loadings check runs only after
///   `ratio >= minRatio` with `minRatio > 1`, which forces λ1 to be simple,
///   and then the global sign normalization suffices. Do not move the
///   loadings check ahead of the ratio check — the argument silently
///   dies and no test catches it (#39 verify R1, logic L1).
/// - The operative form of CCT's "all loadings positive" is therefore
///   "no ZERO loadings": an exact block partition puts the leading
///   eigenvector entirely on one block and zeros on the other. The two
///   conditions are complementary ONLY for exact partitions (cross-block
///   agreement exactly 0): agreement values are ratios k/n, so a nonzero
///   cross-block value is at least 1/n ≫ the zero-loading epsilon, and a
///   weakly-coupled minority block then evades BOTH conditions.
///   Reproducible construction (R2-verified): four engines mutually
///   agreeing at 0.9 plus one outsider coupled at 0.05 passes with
///   ratio ≈ 48 and minimum loading ≈ 0.007. Known limitation of the
///   check as specified; a relative-loading detector is tracked in #48.
///   A `passed` verdict is NOT proof that no substructure exists.
/// - Eigen decomposition is a hand-written cyclic Jacobi: convergent for
///   symmetric matrices and fully unit-testable against analytic spectra.
///   The 100-sweep cap is a truncation, so the result carries a `converged`
///   flag and the check refuses to issue a verdict on an unconverged
///   eigensystem (untestable — R1 codex C2). Power iteration was rejected
///   because it fails to converge precisely when λ1 ≈ λ2 — the regime this
///   check must measure. Cost is O(sweeps·n³): measured ~1s at n = 100,
///   ~12s at n = 200 (M5 Max); the shipped surface caps engines at ≲ 10.
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
    ///
    /// `failed` carries the measured ratio when the eigen ran (nil only on
    /// the λ1 ≈ 0 branch, where no ratio exists) — the number is most
    /// valuable exactly when the check refuses (R1 F-05).
    public enum Verdict: Equatable {
        case passed(ratio: Double, loadings: [String: Double])
        case failed(reason: String, ratio: Double?)
        case untestable(reason: String)
    }

    /// λ1/λ2 refusal threshold. A value ≤ 1 is meaningless (λ1 ≥ λ2 always),
    /// so like #38's `minCoAnswerThreshold` any unusable override falls back
    /// to the default rather than silently disabling the gate. `isFinite` is
    /// load-bearing: "inf" would pass `v > 1` and refuse every run.
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
    /// `ratioUnbounded` in the result records whether the λ2 clamp engaged
    /// (λ2 ≤ 1e-12 — rank-1-like agreement): the ratio value is then a clamp
    /// artifact, not a measurement, and consumers must read the flag, never
    /// infer clamping from the number's magnitude (R2 — codex 4 / NEW-8).
    ///
    /// Precondition: the sparse dictionary is expected in `agreementMatrix`
    /// shape — bidirectionally populated and non-negative. Values are
    /// symmetrized defensively, but the included/excluded split reads each
    /// engine's own row; a caller populating pairs one-way under-includes.
    public static func singleConsensusCheck(
        agreement: [String: [String: Double]],
        engines: [String],
        minRatio: Double
    ) -> (verdict: Verdict, excluded: [String], ratioUnbounded: Bool) {
        let included = engines.filter { !(agreement[$0] ?? [:]).isEmpty }.sorted()
        let excluded = engines.filter { (agreement[$0] ?? [:]).isEmpty }.sorted()
        guard included.count >= 3 else {
            return (.untestable(reason: "only \(included.count) engine(s) with "
                        + "co-answer data — the single-consensus check needs ≥ 3"),
                    excluded, false)
        }
        let dense = denseAgreement(from: agreement, engines: included)
        guard dense.allSatisfy({ row in row.allSatisfy(\.isFinite) }) else {
            // Non-finite values mean the upstream matrix is corrupt, not that
            // engines disagree — misattributing this as "no agreement
            // structure" (or as non-convergence: NaN poisons the off-norm
            // comparison too) sends debugging the wrong way (R1 security L1).
            // Checked BEFORE the eigen so the diagnosis names the real cause.
            // NOTE the verdict is fail-closed but the RUN proceeds — an
            // untestable check discloses, it does not refuse (same contract
            // as the <3-engines branch; R2 security NEW-5).
            return (.untestable(reason: "non-finite values in the agreement "
                        + "matrix — upstream computation corrupt; cannot test"),
                    excluded, false)
        }
        let eigen = jacobiEigen(dense)
        guard eigen.converged else {
            // Theoretically unreachable at these sizes (Jacobi converges in a
            // handful of sweeps for n ≤ ~200), but an unconverged eigensystem
            // must never silently produce a verdict. Verdict-level
            // fail-closed; the run proceeds with disclosure (R1 codex C2,
            // R2 security NEW-5).
            return (.untestable(reason: "eigen decomposition did not converge "
                        + "within the sweep cap — cannot certify a verdict"),
                    excluded, false)
        }
        let lambda1 = eigen.values[0]
        guard lambda1 > 1e-9 else {
            // Numerical-zero judgement, not exact zero (λ1 = 5e-10 lands
            // here too); no ratio exists on this branch (0/0 undefined).
            return (.failed(reason: "single-consensus check failed: no agreement "
                        + "structure — engines co-answer but never agree "
                        + "(λ1 ≈ 0, below numerical threshold 1e-9); there is "
                        + "no shared answer key to estimate",
                            ratio: nil),
                    excluded, false)
        }
        let ratioUnbounded = eigen.values[1] <= 1e-12
        let ratio = lambda1 / max(eigen.values[1], 1e-12)
        var lead = eigen.vectors[0]
        if let maxIdx = lead.indices.max(by: { abs(lead[$0]) < abs(lead[$1]) }),
           lead[maxIdx] < 0 {
            lead = lead.map { -$0 }
        }
        var loadings: [String: Double] = [:]
        for (i, id) in included.enumerated() { loadings[id] = lead[i] }
        guard ratio >= minRatio else {
            // Both numbers at %.4f (R1 prescribed UNIFIED precision — R2 DA
            // §3.2 caught the %.2f threshold). This narrows the
            // contradiction window (e.g. ratio 2.99999 rendering as
            // "3.0000 < threshold 3.0000") to ~5e-5; it does NOT eliminate
            // it — full precision lives in the structured fields, which are
            // canonical.
            return (.failed(reason: String(
                        format: "single-consensus check failed: eigenvalue ratio "
                            + "λ1/λ2 = %.4f < threshold %.4f — the agreement structure "
                            + "is consistent with more than one answer key, so "
                            + "the pooled single-key estimate is not defined for "
                            + "this run",
                        ratio, minRatio),
                            ratio: ratio),
                    excluded, ratioUnbounded)
        }
        // Negative loadings cannot arise from valid (non-negative) input —
        // reaching here means the caller violated the precondition; name
        // that, don't call it a zero loading (R2 security NEW-9).
        let negatives = included.filter { (loadings[$0] ?? 0) < -1e-9 }
        guard negatives.isEmpty else {
            return (.failed(reason: "single-consensus check failed: engine(s) "
                        + negatives.joined(separator: ", ")
                        + " have negative first-factor loading — the input "
                        + "violates the non-negativity precondition",
                            ratio: ratio),
                    excluded, ratioUnbounded)
        }
        let outsiders = included.filter { (loadings[$0] ?? 0) <= 1e-9 }
        guard outsiders.isEmpty else {
            let ratioText = ratioUnbounded
                ? "unbounded — λ2 ≈ 0" : String(format: "%.4f", ratio)
            return (.failed(reason: "single-consensus check failed: engine(s) "
                        + outsiders.joined(separator: ", ")
                        + " have zero first-factor loading — they sit outside the "
                        + "leading consensus block (eigenvalue ratio "
                        + ratioText + ")",
                            ratio: ratio),
                    excluded, ratioUnbounded)
        }
        return (.passed(ratio: ratio, loadings: loadings), excluded, ratioUnbounded)
    }

    // MARK: - Internals

    /// Densify the sparse agreement dictionary over `engines` (row/column
    /// order): missing pair → 0, and the two directions are AVERAGED —
    /// `agreementMatrix` is symmetric by construction, so this is a no-op
    /// for every internal caller, but `jacobiEigen` is symmetric-only and a
    /// future asymmetric caller would otherwise get silent non-eigenvalues
    /// (R1 security M3). Diagonal ← row max |off-diagonal| (one-step minres
    /// communality approximation; see type doc).
    static func denseAgreement(from sparse: [String: [String: Double]],
                               engines: [String]) -> [[Double]] {
        let n = engines.count
        var m = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n where i != j {
                let ab = sparse[engines[i]]?[engines[j]] ?? 0
                let ba = sparse[engines[j]]?[engines[i]] ?? 0
                m[i][j] = (ab + ba) / 2
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
    /// (each `vectors[k]` is the unit eigenvector for `values[k]`) and a
    /// convergence flag (off-diagonal norm under tolerance when the sweep
    /// loop ended — the cap is a truncation, so this must be checked).
    static func jacobiEigen(_ matrix: [[Double]])
        -> (values: [Double], vectors: [[Double]], converged: Bool) {
        let n = matrix.count
        var a = matrix
        // Columns of v accumulate the eigenvectors.
        var v = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }
        let tolerance = 1e-24   // squared off-diagonal Frobenius norm
        func offSquared() -> Double {
            var s = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n { s += a[i][j] * a[i][j] }
            }
            return s
        }
        for _ in 0..<100 {
            if offSquared() < tolerance { break }
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
        let converged = offSquared() < tolerance
        let order = (0..<n).sorted { a[$0][$0] > a[$1][$1] }
        return (order.map { a[$0][$0] },
                order.map { col in (0..<n).map { v[$0][col] } },
                converged)
    }
}

/// #39: report-facing record of the single-consensus check. `nil` on a
/// report means the check did not run (pre-#39 report, majority, rover) —
/// absence is never a verdict.
public struct SingleConsensusCheck: Codable, Equatable, Sendable {
    /// "passed" / "failed" / "untestable".
    public let verdict: String
    /// λ1/λ2 — present whenever the eigen ran (passed AND failed; nil on
    /// the λ1 ≈ 0 branch and on untestable). Full precision — the message
    /// string is the human rendering, this is the canonical number.
    public let ratio: Double?
    /// The threshold that was in force (env-overridable, so a verdict is
    /// unreadable without it — condition-tuple discipline, R1 F-04).
    /// Optional ONLY for legacy decode; new checks always carry it (the
    /// initializer requires it — R2 codex 6).
    public let minRatio: Double?
    /// True when the λ2 clamp engaged (rank-1-like agreement): `ratio` is
    /// then a clamp artifact, not a measurement. Read this flag — never
    /// infer clamping from the ratio's magnitude (R2). nil = legacy report.
    public let ratioUnbounded: Bool?
    /// First-factor loadings per included engine (passed only).
    public let loadings: [String: Double]?
    /// Engines excluded for having no co-answer data at all — absence of
    /// evidence, not evidence of a second culture.
    public let excludedEngines: [String]
    /// Explanation for failed / untestable verdicts.
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case verdict, ratio, loadings, reason
        case minRatio = "min_ratio"
        case ratioUnbounded = "ratio_unbounded"
        case excludedEngines = "excluded_engines"
    }

    public init(verdict: ConsensusValidity.Verdict, excluded: [String],
                minRatio: Double?, ratioUnbounded: Bool? = nil) {
        self.excludedEngines = excluded
        self.minRatio = minRatio
        self.ratioUnbounded = ratioUnbounded
        switch verdict {
        case .passed(let ratio, let loadings):
            self.verdict = "passed"
            self.ratio = ratio
            self.loadings = loadings
            self.reason = nil
        case .failed(let reason, let ratio):
            self.verdict = "failed"
            self.ratio = ratio
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
