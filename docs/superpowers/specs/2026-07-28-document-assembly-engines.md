# Document-assembly engines and document-class routing — design spec

- **Date**: 2026-07-28
- **Status**: proposed — pending user review. No implementation has landed.
- **Issue**: #16 (Option A, chosen from the #15 evaluation)
- **Decision**: extend `OCRResult` with an optional structural payload; extend the
  `doc_type` *vocabulary* rather than the condition-tuple *shape*; add an
  assembly capability axis and a document-class query axis.

## 1. Context and motivation

bestOCR does per-page VLM transcription. It has no document-assembly layer —
nothing resolves reading order across columns, and nothing recovers table
structure. The #15 evaluation ran marker 2.0 and the PaddleOCR document
pipeline over a real scanned corpus and established two things:

1. The right engine **depends on document class**. Per-page transcription is
   correct and fast for single-column text and structurally incapable for
   multi-column pages.
2. On Apple Silicon, a **dedicated layout-detection model beats a
   grammar-constrained VLM**. marker's surya layout goes through
   `llama-server`'s `json_schema` → GBNF path, which fails there (~20
   errors/doc) and interleaves headers mid-question; PP-DocLayoutV2 is a
   detection model and sidesteps that path entirely.

Option A followed: make assembly a **routed, evidence-labelled capability**
rather than a hidden default.

This spec exists because the diagnosis on #16 found the work is not "add two
adapters" — every checklist item collides with a core type. Those collisions
are decided here.

## 2. Requirements

| Axis | Decision |
|------|----------|
| Assembly output | Must survive into the result type. Flattening an assembly engine's output into `[PageResult]` discards the ordering the engine exists to produce — the failure mode most likely to pass tests and still be wrong |
| Engine roster | `doc.paddleocr-pipeline` (Mac-native, CPU) and `doc.marker` (fast, best inline-math LaTeX, Mac-fragile layout) |
| Routing | `recommend` / `AutoRouter` gain a document-class axis; every fallback hop stays printed, never silent |
| Estimands | Reading-order fidelity and table-structure fidelity, each with a **named, versioned formula** (schema hard rule 2) |
| Backward compatibility | Existing `evidence/rows.jsonl` must stay decodable; existing engine and `WorkloadSpec` call sites must keep compiling |
| Honesty | Per-engine tradeoffs are labelled, not ranked into a single winner. Neither assembly engine is good at everything |

## 3. Non-goals

- No adjudicator work — that is #17.
- No change to `repos/measureOCR` (article 1 freeze).
- No cloud engines in assembly routing (reference tier only, unchanged).
- No automatic promotion of assembly runs into `evidence/` (explicit ingest
  only, unchanged).
- **No reading-order or table numbers claimed until an annotated reference
  subset exists** — see §6.3. Defining an estimand and measuring it are
  separate acts, and this spec only does the first.

## 4. Decision 1 — result shape

### 4.1 The problem

```swift
public struct OCRResult: Sendable, Codable {
    public let engineID: String
    public let pages: [PageResult]      // PageResult.text is a flat String
    public let condition: ConditionTuple
}
```

Two shapes were considered:

**(a) Extend `OCRResult` with an optional structural payload.**
**(b) Introduce a sibling `DocumentResult` and a second engine protocol.**

### 4.2 Decision: (a)

`OCRResult` gains one optional field:

```swift
public struct OCRResult: Sendable, Codable {
    public let engineID: String
    public let pages: [PageResult]
    public let condition: ConditionTuple
    /// Non-nil only for engines whose `capabilities.assembly != .none`.
    /// Per-page engines leave this nil and lose nothing.
    public let document: DocumentStructure?
}

/// Reading order IS the array order of `blocks` — there is deliberately no
/// separate order index, so there is exactly one source of truth for it.
public struct DocumentStructure: Sendable, Codable {
    public let blocks: [DocumentBlock]
}

public struct DocumentBlock: Sendable, Codable {
    public let page: Int
    public let kind: BlockKind
    public let text: String            // this block's rendering (markdown for tables)
    public let bbox: BoundingBox?      // normalized [0,1] page coords, when reported
}

public enum BlockKind: String, Sendable, Codable {
    case heading, paragraph, list, table, figure, formula, header, footer, other
}
```

**Why (a) over (b):**

- **One result type keeps flowing.** `RunPipeline`, `RunLog`, `EvidenceIngest`,
  and `ConsensusPipeline` all consume `OCRResult` today. A sibling type forks
  every one of those into a branch, and `AutoRouter` would have to know which
  protocol each engine implements before it can fall back between them —
  fallback across the per-page/assembly boundary is precisely what routing
  needs to do.
- **Decoding stays backward-compatible.** An optional `Codable` field decodes
  as `nil` when absent, so every existing row in `evidence/rows.jsonl` and every
  archived `*.ocr-meta.json` still reads.
- **`pages` stays populated by assembly engines**, carrying per-page timing and
  `thermalState` exactly as before, so speed estimands are unaffected and
  comparable across engine classes.

**What (a) costs, stated plainly:** `OCRResult` now has a field that is
meaningful for only some engines. That is a real wart. It is accepted because
the alternative pushes an `if` into four call sites and a protocol split into
the router, and because `capabilities.assembly` makes the nil-ness predictable
rather than mysterious — a consumer can tell from the engine whether to expect
structure, without probing the result.

### 4.3 The invariant that must be tested

When `document != nil`, concatenating `blocks` in array order MUST reproduce
the same content as `pages` joined in page order — same text, possibly
different order. This is what makes `OCRResult.text` remain meaningful for
assembly engines, and it is the property that catches a broken adapter.

## 5. Decision 2 — evidence contract

### 5.1 The question

Does document-class enter `ConditionTuple`?

```swift
public struct ConditionTuple: Sendable, Codable {
    public let model, quant: String
    public let dpi: Double?
    public let docType: String       // encoded as "doc_type"
    public let platform, hardware, instrument: String
}
```

### 5.2 Decision: no — extend the `doc_type` *vocabulary*, not the tuple *shape*

Adding a field would change the serialized shape of every future row while
every existing row lacks it, forcing a migration for no experimental gain.

Instead, document-class is expressed by **new `doc_type` values**:

| New `doc_type` | Meaning |
|---|---|
| `multicolumn_scan` | scanned multi-column page; reading order is the hard part |
| `tabular_doc` | table-dominant document |

`doc_type` already *is* the corpus-class field, and it is already free-form
(`String`, not an enum), so this is a vocabulary addition with **zero
migration** and zero decoding risk. A comparison between an assembly engine and
a per-page engine on `multicolumn_scan` is then a valid within-tuple comparison
by the existing rules, with no new rules needed.

The **query-side** axis — what the caller is asking for — is a different thing
and lives in `WorkloadSpec` (§7.2). Keeping the query axis out of the evidence
tuple is the point: the tuple records *what was measured*, not *what someone
asked for*.

### 5.3 Estimand naming: fix the existing inconsistency here

`evidence/schema.md` §2 names estimands unversioned (`speed.ms_per_page`,
`quality.word_recall`) while shipped code and the README use versioned names
(`quality.token_recall_vs_cloud@v1`, `speed.ensemble_ms_per_page@v1`). The
schema document is what every number is supposed to trace back to, so the
disagreement is fixed in the same edit that adds the new estimands:

- Versioned names (`name@vN`) become the schema's stated form.
- A compatibility line records that pre-existing unversioned names are read as
  `@v1`, so no row is rewritten.

This is folded in rather than filed separately because it is literally the same
paragraph of the same file.

## 6. Decision 3 — the two new estimands

Both are **defined here and unmeasured until §6.3 is satisfied.** Naming an
estimand without a formula is what schema hard rule 2 forbids; claiming a
number without a reference is what tier discipline forbids. This spec does the
first and explicitly refuses the second.

### 6.1 `quality.reading_order_tau@v1`

Kendall's tau-b between the engine's block sequence and a reference block
sequence, after matching blocks one-to-one by normalized-text similarity.

- Range [−1, 1]; 1 is identical order.
- **Why tau-b**: it counts discordant pairs, so a single block displaced far
  from its correct position (marker's header-interleaving failure) is penalised
  in proportion to how far it travelled — which is the phenomenon being
  measured. Ties are handled by tau-b's correction, which matters because
  matching can leave equal-similarity candidates.
- Blocks the engine produced that match no reference block, and reference
  blocks the engine missed, are **excluded from the correlation and reported
  separately** as unmatched counts. Folding them into the coefficient would
  silently blend a *detection* failure into an *ordering* score — two different
  estimands.

### 6.2 `quality.table_structure_f1@v1`

Cell-level F1. Each recovered table cell is the triple
`(row index, column index, normalized text)`; compare the produced set against
the reference set; report precision, recall, and their harmonic mean.

- **Why cell-level rather than whole-table matching**: it degrades gracefully.
  A table recovered with one merged column still scores most of its cells,
  whereas whole-table matching would score zero and hide the difference between
  "nearly right" and "entirely wrong".
- It also captures the PaddleOCR pipeline's known quirk correctly: emitting a
  multiple-choice block as a spurious table injects cells that match nothing,
  so **precision** drops while recall is untouched — which is exactly the right
  description of that failure.

### 6.3 What both require, stated as a blocker not a footnote

Both need a **reference annotation**: a human-checked block sequence and cell
set for a subset of pages. bestOCR has no such subset today.

Until it exists, both estimands are **defined but unmeasured**, and
`recommend` MUST continue to answer *evidence-pending* for anything that would
depend on them. Building the annotated subset is a separate piece of work with
its own honesty problem (who annotates, and against what rendering), and is
deliberately not smuggled in here.

The corpus used in #15 is third-party exam material and stays on-machine, so it
cannot become a committed reference set. The annotated subset must be built
from redistributable material.

## 7. Decision 4 — capability and routing surfaces

### 7.1 Engine family and capability

`EngineFamily` gains a case:

```swift
case documentPipeline = "document_pipeline"
```

Adding an enum case is decode-safe: existing rows contain only pre-existing raw
values, so nothing already written fails to decode.

`EngineCapabilities` gains an assembly axis, **defaulted** so all 14 existing
construction sites (7 in `Sources/`, 7 in `Tests/`) keep compiling unchanged:

```swift
public enum AssemblyCapability: String, Sendable, Codable {
    case none          // per-page transcription; no cross-block ordering
    case readingOrder  // resolves multi-column / reading order
    case fullStructure // reading order + table structure
}

public init(outputLevel: OutputLevel, languages: [String],
            needsNetwork: Bool, memoryClass: MemoryClass,
            assembly: AssemblyCapability = .none)   // ← defaulted
```

`OutputLevel` is deliberately **not** reused for this. It describes *text*
fidelity (`plainText` / `markdown` / `mathMarkdown`); an engine can emit
`mathMarkdown` and still interleave headers mid-question — which is exactly
what marker does. Conflating the two axes would make the routing predicate
unexpressible.

### 7.2 Workload query axis

```swift
public enum DocumentClass: String, Sendable, CaseIterable {
    case unspecified, singleColumn, multiColumn, tabular, mixed
}
```

added to `WorkloadSpec` as `documentClass: DocumentClass = .unspecified`,
defaulted so existing call sites (CLI, MCP `recommend` tool, `AutoRouter`,
`Recommender`) keep compiling; each surface then opts in explicitly.

### 7.3 Routing rule

```
documentClass ∈ {multiColumn, tabular, mixed}
    → require capabilities.assembly != .none
documentClass ∈ {singleColumn, unspecified}
    → no assembly constraint (existing behaviour, unchanged)
```

Two honesty requirements on top of the filter:

1. **The cost must be surfaced, not just the correctness win.** The paddle
   pipeline runs CPU-only on Apple Silicon and is substantially slower than the
   Ollama per-page path. Auto-routing to it silently trades a large speed
   regression for reading order the caller may not have needed. The printed
   routing line must say so.
2. **Fallback hops stay printed** — the existing product invariant applies
   across the per-page/assembly boundary too.

## 8. Engine roster

| id | family | assembly | Honest tradeoff |
|---|---|---|---|
| `doc.paddleocr-pipeline` | `documentPipeline` | `fullStructure` | Correct reading order on Apple Silicon (PP-DocLayoutV2 is a detection model, not grammar-constrained). CPU-only, slow. Heavier install (`paddleocr` + `paddlepaddle` + `paddlex[ocr]`). Known quirk: can emit a multiple-choice block as one table. No LaTeX |
| `doc.marker` | `documentPipeline` | `readingOrder` | Fast; best inline-math LaTeX of the three engines compared. **Layout is fragile on the llama.cpp path** — surya's `json_schema` → GBNF conversion fails, so headers/footers interleave. Text and inline math survive because they go through the recognition VLM |

`doc.marker` is admitted at `readingOrder`, not `fullStructure`, and with the
fragility stated in its probe hint — admitting an engine whose signature
capability is known-degraded on the target platform is only defensible if the
degradation travels with it.

Both ship as protocol-v1 external adapters, matching the existing
`Adapters/AdapterScripts.swift` pattern.

## 9. Phasing

| Phase | Content | Gate |
|---|---|---|
| 0 | `DocumentStructure` / `DocumentBlock` / `BlockKind`; `OCRResult.document`; §4.3 invariant test | decode-compat test against the committed `evidence/rows.jsonl` |
| 0b | `evidence/schema.md`: new `doc_type` values, versioned-name fix + compat line | schema doc and code agree |
| 1 | `EngineFamily.documentPipeline`; `AssemblyCapability` (defaulted) | all 14 existing capability sites compile untouched |
| 2 | Estimand definitions in `evidence/schema.md` with formulas | formulas stated; no numbers claimed |
| 3 | `doc.paddleocr-pipeline`, then `doc.marker` adapters | probe-gated; honest install hints |
| 4 | `DocumentClass` axis; routing rule; cost surfacing | fallback hops printed; speed cost printed |
| 5 | Tradeoff labels in `list-engines` / `recommend` output | no single-winner ranking across classes |

Phases 0 and 0b are the irreversible ones and are why this document exists.
Phases 1–5 are mechanical once they are settled.

## 10. Testing

Follows the repo's existing Swift Testing suite and the ≥80% coverage rule.

- **Decode compatibility**: the committed `evidence/rows.jsonl` decodes
  unchanged after the `OCRResult` and `EngineFamily` changes. This is the test
  that would catch the one genuinely dangerous edit in this spec.
- **§4.3 invariant**: for a fixture assembly result, block-order concatenation
  and page-order concatenation carry the same content.
- **Routing**: `multiColumn` excludes `assembly == .none` engines;
  `singleColumn` and `unspecified` leave existing selection byte-identical.
- **Capability defaulting**: existing engine constructions compile and their
  reported capabilities are unchanged (`assembly == .none`).
- **Estimand formulas**: unit-tested against hand-computed cases — a known
  permutation with a known tau, a table with a known F1, and the
  spurious-table case that must drop precision without touching recall.

Adapters are probe-gated, so their tests skip when the Python tooling is
absent, as the existing external-adapter tests already do.

## 11. Relationship to #17

`ConsensusPipeline.adjudicate(results: [String: OCRResult])` consumes the type
this spec changes. Because the change is an **added optional field**, #17's
phases 0–2 — which operate below the `AlignedItem` boundary — are unaffected
and may proceed in parallel.

#17's phase 0b (recording adjudicator identity) and phases 3+ (competence
priors read from evidence rows) touch `evidence/schema.md`, which §5.3 also
edits. Those must land after this spec's phase 0b, or the two will make
conflicting edits to the same file.

There is also a real opportunity: a `DocumentStructure` gives the consensus
layer block-level alignment, which is strictly better than the current
line-primary heuristic for multi-column input. Noted, not scoped here.

## 12. Open questions (deferred, not blockers)

- **Who annotates the reference subset, against what rendering** (§6.3). Until
  answered, both new estimands stay unmeasured. This is the largest open item
  and the honest reason "add reading-order fidelity" is not a one-sprint task.
- **Whether `doc.marker` should be admitted at all on Apple Silicon**, given
  its layout degradation. It earns its place on inline-math LaTeX; if the
  routing never selects it, that is evidence it should be reference-tier
  instead. Revisit once §6.3 makes the comparison measurable.
- **Whether `bbox` should be required rather than optional.** Making it
  required would enable geometric reading-order metrics but would exclude any
  engine that does not report coordinates. Left optional until a second metric
  actually needs it.
- **MLX / GPU path for the paddle pipeline.** CPU-only is its main cost;
  whether that is fixable is upstream, not a bestOCR decision.
