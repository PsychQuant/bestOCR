import Foundation
import Testing
@testable import BestOCRKit

/// #39: CCT single-consensus validity check — before any pooling estimator
/// reports competence, test whether the agreement structure is consistent
/// with ONE latent answer key (eigenvalue ratio + first-factor loadings).
/// Failing either means the competence estimand does not exist for the run.
struct ConsensusValidityTests {

    // MARK: - Jacobi eigen (numerical anchor)

    @Test func jacobiMatchesAnalytic2x2() {
        // [[2,1],[1,2]] has exact spectrum {3, 1}; leading vector (1,1)/√2.
        let result = ConsensusValidity.jacobiEigen([[2, 1], [1, 2]])
        #expect(abs(result.values[0] - 3) < 1e-12)
        #expect(abs(result.values[1] - 1) < 1e-12)
        let inv = 1.0 / 2.0.squareRoot()
        #expect(abs(abs(result.vectors[0][0]) - inv) < 1e-12)
        #expect(abs(abs(result.vectors[0][1]) - inv) < 1e-12)
    }

    @Test func jacobiMatchesPrecomputed4x4() {
        // numpy.linalg.eigh fixture (generated 2026-08-05):
        //   A = [[4,1,.5,.2],[1,3,.3,.1],[.5,.3,2,.4],[.2,.1,.4,1]]
        let a: [[Double]] = [[4, 1, 0.5, 0.2],
                             [1, 3, 0.3, 0.1],
                             [0.5, 0.3, 2, 0.4],
                             [0.2, 0.1, 0.4, 1]]
        let expected = [4.766339371742, 2.382602385610, 1.991633490670, 0.859424751979]
        let expectedLead = [0.828327607336, 0.510317604304, 0.216704845793, 0.080550155010]
        let result = ConsensusValidity.jacobiEigen(a)
        for (got, want) in zip(result.values, expected) {
            #expect(abs(got - want) < 1e-9)
        }
        // Eigenvector sign is arbitrary — compare after orienting positive.
        var lead = result.vectors[0]
        if let maxIdx = lead.indices.max(by: { abs(lead[$0]) < abs(lead[$1]) }),
           lead[maxIdx] < 0 { lead = lead.map { -$0 } }
        for (got, want) in zip(lead, expectedLead) {
            #expect(abs(got - want) < 1e-9)
        }
    }

    // MARK: - Check fixtures (sparse agreement dictionaries, agreementMatrix shape)

    /// All four engines agree 0.8 pairwise — one culture.
    private func singleCulture() -> [String: [String: Double]] {
        var m: [String: [String: Double]] = [:]
        let ids = ["a", "b", "c", "d"]
        for x in ids {
            for y in ids where x != y { m[x, default: [:]][y] = 0.8 }
        }
        return m
    }

    /// The #39 observed shape: {a,b} agree, {c,d} agree, the two blocks
    /// never co-answer (missing entries — agreementMatrix writes nothing).
    private func partitioned() -> [String: [String: Double]] {
        ["a": ["b": 0.8], "b": ["a": 0.8],
         "c": ["d": 0.8], "d": ["c": 0.8]]
    }

    @Test func singleCultureFixturePasses() {
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: singleCulture(), engines: ["a", "b", "c", "d"], minRatio: 3)
        guard case .passed(let ratio, let loadings) = check.verdict else {
            Issue.record("expected passed, got \(check.verdict)")
            return
        }
        #expect(ratio >= 3)
        #expect(ratio.isFinite)
        #expect(loadings.count == 4)
        #expect(loadings.values.allSatisfy { $0 > 1e-9 })
        #expect(check.excluded.isEmpty)
    }

    @Test func partitionFixtureFails() {
        // Two equal blocks → λ1 ≈ λ2 → ratio ≈ 1 < 3. The refusal reason
        // must carry the measured ratio (issue Expected: "a refusal with the
        // eigenvalue ratio in the message is enough") — AND the structured
        // ratio must be populated too (R1 F-05: the number is most valuable
        // exactly when the check refuses; a null field forces regex parsing).
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: partitioned(), engines: ["a", "b", "c", "d"], minRatio: 3)
        guard case .failed(let reason, let ratio) = check.verdict else {
            Issue.record("expected failed, got \(check.verdict)")
            return
        }
        #expect(reason.contains("1.0"))
        #expect(reason.lowercased().contains("eigenvalue ratio"))
        #expect(ratio != nil)
        #expect(abs((ratio ?? 0) - 1.0) < 0.01)
    }

    @Test func issueObservedMatrixIsRefused() {
        // The #39 motivating run, verbatim: exactly the pairwise entries the
        // issue's Actual section shows (symmetric completion; unshown pairs
        // have NO entry). tesseract's row is all zeros — present entries with
        // value 0 (co-answered, never agreed), so it is INCLUDED, not
        // excluded. numpy cross-check: ratio 1.5748 < 3 → failed on the
        // ratio condition; tesseract loading is exactly 0 (second line of
        // defense agrees). This is the issue's only empirical evidence —
        // pinned so it can never silently start passing.
        var m: [String: [String: Double]] = [:]
        func put(_ a: String, _ b: String, _ v: Double) {
            m[a, default: [:]][b] = v
            m[b, default: [:]][a] = v
        }
        put("tesseract", "doc.marker", 0.0)
        put("tesseract", "ext.rapidocr", 0.0)
        put("tesseract", "ext.surya", 0.0)
        put("tesseract", "vision", 0.0)
        put("doc.marker", "ext.surya", 0.0)
        put("doc.marker", "vision", 0.5)
        put("ext.surya", "ext.rapidocr", 0.54)
        put("ext.surya", "ext.cnocr", 0.36)
        put("ext.surya", "vision", 0.47)
        let engines = ["doc.marker", "ext.cnocr", "ext.rapidocr",
                       "ext.surya", "tesseract", "vision"]
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: m, engines: engines, minRatio: 3)
        guard case .failed(let reason, let ratio) = check.verdict else {
            Issue.record("expected failed, got \(check.verdict)")
            return
        }
        #expect(reason.contains("1.57"))
        #expect(abs((ratio ?? 0) - 1.5748) < 0.001)
        #expect(check.excluded.isEmpty)   // all six co-answered someone
    }

    @Test func nonFiniteAgreementIsUntestableNotMisattributed() {
        // R1 security L1: NaN input was fail-closed (good) but the message
        // blamed "engines never agree" — wrong attribution sends debugging
        // the wrong way. Non-finite values are an upstream-corruption signal:
        // untestable, with the real cause named.
        let m: [String: [String: Double]] = [
            "a": ["b": Double.nan, "c": 0.5],
            "b": ["a": Double.nan, "c": 0.5],
            "c": ["a": 0.5, "b": 0.5],
        ]
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: m, engines: ["a", "b", "c"], minRatio: 3)
        guard case .untestable(let reason) = check.verdict else {
            Issue.record("expected untestable, got \(check.verdict)")
            return
        }
        #expect(reason.lowercased().contains("non-finite"))
    }

    @Test func asymmetricInputIsSymmetrized() {
        // R1 security M3: jacobiEigen assumes symmetry; an asymmetric dict
        // (impossible from agreementMatrix today, possible from a future
        // caller) silently produced non-eigenvalues. denseAgreement now
        // symmetrizes: m[i][j] = m[j][i] = (a_ij + a_ji) / 2.
        let m: [String: [String: Double]] = ["a": ["b": 1.0], "b": ["a": 0.0]]
        let dense = ConsensusValidity.denseAgreement(from: m, engines: ["a", "b"])
        #expect(dense[0][1] == dense[1][0])
        #expect(abs(dense[0][1] - 0.5) < 1e-12)
    }

    @Test func jacobiReportsConvergence() {
        // R1 codex C2: 100 sweeps is a truncation — "unconditionally
        // convergent" is a property of the untruncated algorithm. The result
        // now carries a convergence flag; real inputs at n ≤ ~200 converge
        // in a handful of sweeps, and the check refuses to issue a verdict
        // (untestable) if the flag ever comes back false.
        let a: [[Double]] = [[4, 1, 0.5, 0.2],
                             [1, 3, 0.3, 0.1],
                             [0.5, 0.3, 2, 0.4],
                             [0.2, 0.1, 0.4, 1]]
        #expect(ConsensusValidity.jacobiEigen(a).converged)
        #expect(ConsensusValidity.jacobiEigen([[2, 1], [1, 2]]).converged)
    }

    @Test func checkRecordsMinRatioForReplay() {
        // R1 F-04: the threshold is env-overridable, so a report saying
        // "passed, ratio 3.4" is unreadable without the threshold that was
        // in force. Same condition-tuple discipline as evidence rows.
        let passed = SingleConsensusCheck(
            verdict: .passed(ratio: 5.0, loadings: ["a": 0.7, "b": 0.7, "c": 0.1]),
            excluded: [], minRatio: 3.0)
        #expect(passed.minRatio == 3.0)
        let failed = SingleConsensusCheck(
            verdict: .failed(reason: "eigenvalue ratio λ1/λ2 = 1.5748 < threshold 3.00",
                             ratio: 1.5748),
            excluded: [], minRatio: 3.0)
        #expect(failed.ratio == 1.5748)
        #expect(failed.minRatio == 3.0)
    }

    @Test func zeroLoadingEngineFails() {
        // c co-answers with a and b but NEVER agrees (entries present, value
        // 0) — c sits outside the leading consensus block; loading is 0.
        let m: [String: [String: Double]] = [
            "a": ["b": 0.9, "c": 0.0],
            "b": ["a": 0.9, "c": 0.0],
            "c": ["a": 0.0, "b": 0.0],
        ]
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: m, engines: ["a", "b", "c"], minRatio: 3)
        guard case .failed(let reason, let ratio) = check.verdict else {
            Issue.record("expected failed, got \(check.verdict)")
            return
        }
        #expect(reason.contains("engine(s) c"))
        #expect(reason.lowercased().contains("loading"))
        #expect(ratio != nil)   // the eigen ran — the number exists, record it
    }

    @Test func noAgreementStructureFails() {
        // Everyone co-answers, nobody ever agrees: λ1 = 0 — there is no
        // shared answer key at all, not even a contested one.
        let m: [String: [String: Double]] = [
            "a": ["b": 0.0, "c": 0.0],
            "b": ["a": 0.0, "c": 0.0],
            "c": ["a": 0.0, "b": 0.0],
        ]
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: m, engines: ["a", "b", "c"], minRatio: 3)
        guard case .failed(let reason, let ratio) = check.verdict else {
            Issue.record("expected failed, got \(check.verdict)")
            return
        }
        #expect(reason.lowercased().contains("no agreement structure"))
        // λ1 ≤ ε is a numerical-zero judgement, not exact zero (R1 codex C3);
        // no ratio exists on this branch (0/0 undefined) — nil, honestly.
        #expect(reason.contains("≈ 0"))
        #expect(ratio == nil)
    }

    @Test func rank1PerfectAgreementPasses() {
        // Perfect pairwise agreement → rank-1 matrix, λ2 = 0. The λ2 clamp
        // must keep the reported ratio finite (JSON finiteness discipline).
        var m: [String: [String: Double]] = [:]
        for x in ["a", "b", "c"] {
            for y in ["a", "b", "c"] where x != y { m[x, default: [:]][y] = 1.0 }
        }
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: m, engines: ["a", "b", "c"], minRatio: 3)
        guard case .passed(let ratio, _) = check.verdict else {
            Issue.record("expected passed, got \(check.verdict)")
            return
        }
        #expect(ratio.isFinite)
        #expect(ratio >= 3)
        // The λ2 clamp engaged — the result must SAY so, because the ratio
        // number is a clamp artifact and downstream must not average it
        // into anything (R2).
        #expect(check.ratioUnbounded)
    }

    @Test func excludedEngineDisclosed() {
        // d never co-answered anyone (no entries at all — the tesseract
        // shape from the observed run). Absence of evidence is not evidence
        // of a second culture: d is excluded, the check runs on {a,b,c},
        // and the exclusion is disclosed.
        var m = singleCulture()
        m["d"] = nil
        for k in m.keys { m[k]?["d"] = nil }
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: m, engines: ["a", "b", "c", "d"], minRatio: 3)
        guard case .passed(let ratio, let loadings) = check.verdict else {
            Issue.record("expected passed, got \(check.verdict)")
            return
        }
        #expect(ratio >= 3)
        #expect(loadings.count == 3)
        #expect(loadings["d"] == nil)
        #expect(check.excluded == ["d"])
    }

    @Test func untestableBelowThreeEngines() {
        // Two co-answering engines cannot distinguish one culture from two
        // (CCT needs ≥ 3 informants). Untestable is disclosed, not silent —
        // and it is NOT a pass.
        let m: [String: [String: Double]] = ["a": ["b": 0.9], "b": ["a": 0.9]]
        let check = ConsensusValidity.singleConsensusCheck(
            agreement: m, engines: ["a", "b", "c"], minRatio: 3)
        guard case .untestable(let reason) = check.verdict else {
            Issue.record("expected untestable, got \(check.verdict)")
            return
        }
        #expect(reason.contains("2"))
        #expect(check.excluded == ["c"])
    }

    // MARK: - Threshold config (mirror of #38 minCoAnswerThreshold discipline)

    @Test func envGarbageFallsBackToDefault() {
        #expect(ConsensusValidity.minEigenRatio(env: [:]) == 3.0)
        #expect(ConsensusValidity.minEigenRatio(
            env: ["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO": "banana"]) == 3.0)
        // A ratio threshold ≤ 1 is meaningless (λ1 ≥ λ2 always) — garbage.
        #expect(ConsensusValidity.minEigenRatio(
            env: ["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO": "0.5"]) == 3.0)
        #expect(ConsensusValidity.minEigenRatio(
            env: ["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO": "5.5"]) == 5.5)
        // Non-finite pins (R1 security L3): the isFinite guard is
        // load-bearing — "inf" would pass `v > 1` and make `ratio >= inf`
        // refuse every run. These lines make deleting the guard turn red.
        #expect(ConsensusValidity.minEigenRatio(
            env: ["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO": "inf"]) == 3.0)
        #expect(ConsensusValidity.minEigenRatio(
            env: ["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO": "nan"]) == 3.0)
        #expect(ConsensusValidity.minEigenRatio(
            env: ["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO": "1e400"]) == 3.0)
        #expect(ConsensusValidity.minEigenRatio(
            env: ["BESTOCR_CONSENSUS_MIN_EIGEN_RATIO": ""]) == 3.0)
    }
}
