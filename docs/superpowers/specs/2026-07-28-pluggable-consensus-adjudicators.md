# Pluggable consensus adjudicators — design spec

- **Date**: 2026-07-28
- **Status**: proposed — pending user review. No implementation has landed.
- **Issue**: #17
- **Decision**: generalize `ConsensusEstimate` so "not applicable" is
  representable; qualify consensus-derived estimand *names* by adjudicator;
  give ROVER its own alignment path rather than forcing it through
  `AlignedItem`.

## 1. Context and motivation

`bestocr consensus` hard-wires one adjudicator: `ConsensusEstimator`'s
Dawid-Skene-lite. Its own header states the reduction — no confusion matrix, no
directional error discrimination. That is one point in a large space of
latent-truth / rater-aggregation models, and the maintainer's field (CCT/GCM,
IRT, Thurstonian) is exactly the space it sits in.

The #17 diagnosis found the blocker is **not** the hard-wiring. The injection
point is one line:

```swift
// ConsensusPipeline.adjudicate(results:)
return ConsensusEstimator.estimate(items: allItems)
```

The blocker is that `ConsensusEstimate` is a **Dawid-Skene-shaped return
type**, so the other adjudicators cannot report through it honestly.

## 2. Requirements

| Axis | Decision |
|------|----------|
| Return contract | "Not applicable" must be distinguishable from "empty". A naive-majority adjudicator returning empty competence maps currently reads as "no engines answered" |
| Estimand discipline | Consensus output from different adjudicators are **different estimands** and must be mechanically un-mixable |
| Baseline | Naive majority is the **control**, not a formality — without it the CCT family's benefit is asserted, not measured |
| Sequence models | ROVER needs insertion/deletion representation that `AlignedItem` structurally lacks |
| Backward compatibility | Existing consensus reports and `evidence/rows.jsonl` stay readable |
| Cross-product | The sequence path is shared with bestASR — design the interface for that, build it once |

## 3. Non-goals

- No engine-layer or routing work — that is #16.
- No correction for inter-engine error correlation. The current estimator
  documents that engines sharing failure modes inflate each other's competence
  and offers the pairwise `agreement` matrix as a diagnostic only. **That limit
  survives this spec** — see §8.
- No claim that any adjudicator here is "more correct". They estimate different
  things.

## 4. Decision 1 — generalize the return contract

### 4.1 What each field currently assumes

```swift
public struct ConsensusEstimate: Sendable {
    public let items: [ItemConsensus]
    public let overallCompetence: [String: Double]
    public let competence: [String: [ItemKind: Double]]
    public let agreement: [String: [String: Double]]
    public let iterations: Int
    public let converged: Bool
}
```

| Adjudicator | What breaks |
|---|---|
| naive majority | no competence, no iteration — empty maps are indistinguishable from "nobody answered" |
| full Dawid-Skene | needs a per-engine **confusion matrix**; `[String: [ItemKind: Double]]` is a scalar per kind and cannot hold one. Restoring directional error rates is the entire point of "full vs lite" |
| Bayesian CCT / GCM, IRT | produce **per-item latent parameters** (difficulty, discrimination, guessing). `ItemConsensus` carries only `confidence`, documented as winning weight share — a different quantity |
| all Bayesian | `converged`/`iterations` mean chains and diagnostics, not an EM fixed point |

### 4.2 Decision

```swift
public protocol ConsensusAdjudicator: Sendable {
    /// Stable id; enters the estimand name (§5) and the report.
    static var id: String { get }
    func adjudicate(items: [AlignedItem]) -> ConsensusEstimate
}

public struct ConsensusEstimate: Sendable {
    /// NEW — identity travels with the result, so a report can never be
    /// read without knowing which model produced it.
    public let adjudicator: String
    public let items: [ItemConsensus]
    /// Common diagnostic: pairwise raw agreement over co-answered items.
    /// Computed from the raw responses, so it is adjudicator-independent
    /// and stays comparable across all of them.
    public let agreement: [String: [String: Double]]
    public let diagnostics: AdjudicatorDiagnostics
}

public struct AdjudicatorDiagnostics: Sendable, Codable {
    /// nil  = this adjudicator has no competence concept (naive majority).
    /// [:]  = it has the concept, but no engine qualified.
    public let overallCompetence: [String: Double]?
    public let competence: [String: [ItemKind: Double]]?
    /// nil = non-iterative.
    public let iterations: Int?
    public let converged: Bool?
    /// nil = no confusion model. Present for full Dawid-Skene:
    /// engine → true label → observed label → probability.
    public let confusion: [String: [String: [String: Double]]]?
    /// nil = no latent item parameters. Present for IRT / Bayesian CCT.
    /// An array of pairs rather than a dictionary, because ItemKey is not a
    /// String and JSON-encoding a non-String-keyed dictionary produces a
    /// flat alternating array that is unreadable in a report file.
    public let itemParameters: [ItemParameterEntry]?
}
```

**`nil` means "this model has no such notion"; an empty collection means "it
does, and there was nothing to report".** That single distinction is the fix —
it is what stops a naive-majority report from silently reading like a
degenerate Dawid-Skene one.

### 4.3 The extensibility cost, stated rather than hidden

`AdjudicatorDiagnostics` is a closed set of optional fields. A future
adjudicator reporting a genuinely novel quantity needs a new field — the
closed-set problem in a thinner disguise.

This is accepted **for now** because #17 enumerates its adjudicators, so the
set is known. The alternative — an opaque JSON payload the adjudicator renders
itself — buys openness with type safety and an untyped report writer.

Revisit at phase 4, when IRT lands: it is the first adjudicator with output
that has no analogue in the others, and it is the honest trigger for deciding
whether the closed set still pays. Recording the trigger now is the point;
choosing the open design speculatively is not.

### 4.4 Migration

`ConsensusEstimator` becomes `DawidSkeneLiteAdjudicator: ConsensusAdjudicator`
with `id = "ds-lite"`, keeping its algorithm byte-identical and moving its
current fields into `diagnostics` with all optionals populated. Existing
behaviour is preserved exactly; only the container changes.

`ConsensusPipeline.adjudicate(results:)` gains an adjudicator parameter
defaulting to `DawidSkeneLiteAdjudicator()`, so every existing call site keeps
compiling and behaving identically.

## 5. Decision 2 — adjudicator identity is part of the estimand name

### 5.1 The hazard is already live

`ConsensusPipeline` already emits:

```swift
quality: .init(estimand: "consensus.low_consensus_share@v1", ...)
```

That quantity is **defined by the adjudicator**: "low consensus" currently
means DS-lite's rule (top-weight tie, or fewer than two corroborating
responses). A naive-majority adjudicator would compute a different quantity
under the same name, and a Bayesian one a third — and by `evidence/schema.md`
hard rule 1/3 they would then look rankable against each other.

This is not a hypothetical risk introduced by #17. It is an existing name that
becomes wrong the moment a second adjudicator exists.

### 5.2 Decision: qualify the *name*, not the tuple

Consistent with #16's answer to the same class of question (extend the
vocabulary, not the shape):

```
consensus.<adjudicator-id>.<quantity>@v1
```

| Before | After |
|---|---|
| `consensus.low_consensus_share@v1` | `consensus.ds_lite.low_consensus_share@v1` |
| — | `consensus.majority.low_consensus_share@v1` |
| — | `consensus.<id>.adjudication_ms@v1` (new; see §5.3) |

Different names are mechanically un-mixable under hard rule 2 (no
cross-estimand arithmetic without a named formula). **Zero schema-shape change,
zero row migration.**

Compatibility: rows already carrying the unqualified
`consensus.low_consensus_share@v1` are read as `consensus.ds_lite.*`, because
DS-lite is the only adjudicator that has ever produced it. That is a fact about
the history, not an assumption — recorded in `evidence/schema.md` alongside the
`@v1` compatibility line that #16 phase 0b adds.

### 5.3 Speed stays separate from adjudication cost

`speed.ensemble_ms_per_page@v1` keeps its name. It measures wall-clock
dominated by running N OCR engines, which does not depend on the adjudicator.

Adjudication cost gets its **own** estimand,
`consensus.<id>.adjudication_ms@v1`. It is negligible for plurality and EM and
potentially not negligible for a Bayesian sampler, so folding it into the
ensemble figure would let a sampler's cost masquerade as OCR time. Two costs,
two names.

## 6. Decision 3 — ROVER gets its own alignment path

`AlignedItem` documents its own semantics as: *"An engine absent from
`responses` did not produce an alignable answer for this item."*

That **conflates a deletion with a non-alignment** — precisely the distinction
a confusion network exists to represent (ε-arcs for insertion and deletion at
token level). ROVER cannot be a drop-in adjudicator over this input.

Decision: a second, parallel path rather than a distorted first one.

```swift
public protocol SequenceAdjudicator: Sendable {
    static var id: String { get }
    func adjudicate(network: ConfusionNetwork) -> ConsensusEstimate
}
```

fed by a token-level aligner alongside `ItemExtractor`. It returns the **same**
`ConsensusEstimate` so the report writer and the estimand rules stay shared —
only the input differs.

**Design for sharing, build once.** bestASR needs the identical component for
transcript combination. The aligner and `ConfusionNetwork` should be written so
they can move to a shared package without redesign — but the extraction itself
is not done here, because a shared package with one consumer is speculative
generality.

## 7. Phasing

| Phase | Content | Depends on |
|---|---|---|
| 0 | `ConsensusAdjudicator` protocol; generalized `ConsensusEstimate` + `AdjudicatorDiagnostics`; DS-lite migrated unchanged | — |
| 1 | **Naive majority** adjudicator (the control) | 0 |
| 2 | **Full Dawid-Skene** with confusion matrix | 0 |
| 0b | Adjudicator-qualified estimand names + compat line in `evidence/schema.md` | **#16 phase 0b** (same file) |
| 3 | **Prior-weighted vote** — competence prior from T2 `word_recall` rows via `EvidenceStore` | 0b |
| 4 | **Bayesian CCT / GCM**, then **IRT** (item difficulty, discrimination) | 0, and §4.3 revisit |
| 5 | **ROVER** — token aligner + `ConfusionNetwork` + `SequenceAdjudicator` | 0 |
| 6 | Selection guidance in `consensus` / `recommend`: few vs many engines, categorical vs sequence, with vs without prior — as labelled tradeoffs, never a single ranking | 1–5 |

**Phases 0–2 and 5 are insulated from #16**: they live below the `AlignedItem`
boundary and touch neither `OCRResult` nor `evidence/schema.md`. They can
proceed in parallel with #16.

**Phase 0b and phase 3 must land after #16 phase 0b**, or the two issues make
conflicting edits to `evidence/schema.md`.

Phases 1–2 are the cheap, high-value core: a control plus the model whose
absence the current estimator openly documents. Phases 4–5 are richer
follow-ons whose value is real but unproven on this corpus.

## 8. The limit that survives this spec

Every adjudicator here except full Dawid-Skene and Bayesian CCT inherits the
existing correlated-error problem: engines sharing failure modes inflate each
other's competence, and the `agreement` matrix only *surfaces* it.

Full DS and Bayesian CCT can *model* correlation, but only with enough items
per engine pair to estimate it — which a short document does not provide.

**"More sophisticated model" must not be read as "correlation handled."** The
`agreement` matrix stays in the report for every adjudicator, and the report
must keep saying what it is: a diagnostic, not a correction.

## 9. Testing

- **DS-lite behavioural equivalence**: the migrated adjudicator produces
  byte-identical `items` and competence values to the current implementation on
  the existing fixtures. This is the test that protects the refactor.
- **Not-applicable vs empty**: naive majority returns `competence == nil`;
  a DS-lite run where no item qualifies returns `competence == [:]`. Asserting
  both is what makes §4.2 real rather than aspirational.
- **Estimand naming**: a run under each adjudicator emits a distinctly-named
  estimand; a test asserts no two adjudicators can produce the same name.
- **Naive-majority control**: on a fixture where one engine is deliberately
  unreliable, DS-lite's verdict differs from majority's — demonstrating the
  competence weighting does something. If it does not differ on real corpora,
  that is a finding worth reporting, not a test to weaken.
- **Confusion matrix**: full DS recovers a planted directional confusion
  (e.g. one engine systematically reading `0` as `O`) that DS-lite cannot see.
- **ROVER**: a fixture with a genuine insertion and a genuine deletion, which
  `AlignedItem` cannot represent, round-trips through `ConfusionNetwork`.

## 10. Open questions (deferred, not blockers)

- **Circularity in phase 3.** Using benchmark `word_recall` as a competence
  prior, then promoting consensus results back into evidence rows, risks a loop
  where an engine's prior inflates its influence which inflates its measured
  agreement. Needs an explicit acyclicity rule before phase 3 ships — most
  likely "priors may only come from rows produced by single-engine runs".
- **Whether latent-truth adjudication is the right frame at all.** Every model
  here assumes a single true string per item with engines as noisy informants.
  For layout-ambiguous documents — the class #16 exists to serve — "the true
  reading order" may not be well defined independently of the consumer's
  purpose. No better estimator resolves this; it is a limit on what any
  adjudicator in this issue can mean.
- **Whether block-level alignment from #16's `DocumentStructure` should replace
  the line-primary heuristic** for multi-column input. It would be strictly
  better there. Cross-issue, and gated on #16 phase 0 landing.
- **How many engines make CCT-family models worth their cost.** With two
  engines, competence is barely identifiable and majority is nearly equivalent.
  The answer is empirical and phase 1 is what makes it measurable.
