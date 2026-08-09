# Evidence schema — the labelling contract

Every measurement bestOCR stores or serves carries three labels. A number
without all three is not evidence and must not enter `recommend`.

## 1. Provenance tier

| Tier | Meaning | Example |
|------|---------|---------|
| **T1 pre-registered** | From a frozen, pre-registered design; analysis script pinned before data collection | article 1 sweep `results.tsv` (pending OSF freeze → run) |
| **T2 internal** | Measured on our hardware by our instrument, but exploratory (pilot, smoke test, autotune) | 2026-07-17 pilot: GLM-OCR q4_K_M ≈ 30% faster than f16 at recall ≈ 0.98 |
| **T3 third-party** | Self-reported by the model vendor or an external benchmark we did not run | a model card's OmniDocBench score |

Tier ordering is strict: T1 > T2 > T3. `recommend` ranks on the highest tier
available and *names the tier* in its answer. T3-only candidates are labelled
"unverified — candidate for the next sweep", never ranked beside T1/T2 numbers.

## 2. Estimand

State *what* the number is, precisely enough that two numbers with different
definitions can never be conflated. **Names are versioned: `name@vN`.** A
version bump means the formula changed, so `@v1` and `@v2` are different
estimands and never mix.

*Compatibility*: rows written before this convention carry unversioned names
(`speed.ms_per_page`, `quality.word_recall`). Those are **read as `@v1`** — no
committed row is rewritten. `Estimand.canonical(_:)` in `BestOCRKit` is what
makes this true in code rather than only on paper; without it a legacy row and
a freshly ingested `@v1` row would look like two estimands and split one
ranking into two.

| Estimand | Definition | Status |
|----------|------------|--------|
| `speed.ms_per_page@v1` | wall-clock per page, **warm** model, single stream (model-load time excluded — an engine that loads a heavy pipeline reports load separately) | measured |
| `speed.ensemble_ms_per_page@v1` | total compute across a sequential multi-engine ensemble, per page. Distinct from the above and **never** comparable to it | measured |
| `quality.word_recall@v1` | vs `pdftotext` reference (LaTeX-compiled docs) or archive.org ABBYY layer (scanned docs) — these are *different referents*; label which | measured |
| `quality.token_recall_vs_cloud@v1` | token recall against a cloud engine's output. The referent is a **model output, not ground truth**; never comparable to `word_recall` | measured |
| `quality.reading_order_tau@v1` | Kendall's **tau-b** between the engine's block sequence and a reference block sequence. Matching is greedy one-to-one in produced order on the Dice coefficient over character bigrams of case-folded, whitespace-collapsed text, accepted at **≥ 0.60** (ties broken by lowest reference index, so the result is deterministic). Range [−1, 1]; 1 is identical order; `nil` below two matched pairs. Unmatched blocks (produced-but-absent, reference-but-missed) are **excluded from the coefficient and reported separately** — folding them in would blend a *detection* failure into an *ordering* score | **defined, unmeasured** |
| `quality.table_structure_f1@v1` | cell-level F1 over the set of `(row index, column index, normalized text)` triples: precision, recall, and their harmonic mean. Cell-level rather than whole-table so a table recovered with one merged column still scores most of its cells | **defined, unmeasured** |
| `triage.route_accuracy@v1` | share of pages whose triage-recommended route (`text_direct` / `render_suspect_pages` / `ocr_full`) matches a human-annotated correct route, over an annotated page set: `correct_pages / annotated_pages`. Per-page, so hybrid documents contribute each page separately. The referent is a **human annotation of the correct path**, not any engine output — never comparable to any `quality.*` estimand | **defined, unmeasured** |

Derived scores (e.g. Pareto proxies) must name their formula version.

**Triage thresholds are uncalibrated single-sample inductions.** The defaults
behind `triage.route_accuracy@v1` — text-layer minimum 200 chars/page
(`BESTOCR_TRIAGE_TEXT_MIN`), fragment-ratio maximum 0.6
(`BESTOCR_TRIAGE_FRAG_MAX`) — were induced from one field batch (#35) and are
env-overridable precisely because they are unmeasured. Calibrating them IS the
act of measuring this estimand against the annotated page set (the same
annotation work as the assembly reference subset). Until rows exist, triage
reports remain honest recommendations, not accuracy claims.

**"Defined, unmeasured" is a status, not a placeholder.** Both assembly
estimands require a human-annotated reference subset — a checked block sequence
and cell set for a set of pages — and bestOCR has none. `recommend` therefore
answers *evidence-pending* for anything that would depend on them. Defining an
estimand and measuring it are separate acts; naming one without a formula
violates hard rule 2, and claiming a number without a reference violates tier
discipline.

The mac-benchmark lesson (issues #18–#21) applies verbatim: shares/means that
differ only in estimand or fit are *both true* — report them side by side with
labels, never average them, never pick one silently.

## 3. Condition tuple

`(model, quant, dpi, doc_type, platform, hardware, instrument_commit[, tool_version])` —
every row records the full tuple. A comparison is valid only within matching
tuples (or across a factor the design deliberately varies).

`tool_version` (optional, #28) is the **measuring tool's own** version for
adapter-backed engines (`ext.*`, `doc.*`), reported by the process that produced
the output — `instrument` is bestOCR's version and cannot stand in for it.
Rows written before the field exists simply lack the key; absence decodes as
"unrecorded", never as an error. Honesty boundary: **recording is not a new
ranking rule.** Ranking granularity stays per-model-key (as it already is across
`dpi` and `quant`); whether differing tool versions should partition a ranking is
a separate estimand-semantics decision that this field enables but does not make.

`EngineVersion.interpreter` (#37) is **host-local provenance and is NOT a row
field**: it is an absolute local path (typically carrying the OS username) and
must never enter contributed rows or any shared artifact without deliberate
redaction. If interpreter provenance is ever brought into evidence, that is a
schema decision to be made here first — not a field to thread through quietly.

`triage_text_min` / `triage_frag_max` (**required** for `triage.*` estimands;
bestOCR-bench#1 DA-1): the *effective* thresholds — after `BESTOCR_TRIAGE_*` env
overrides — that produced the routing verdicts being scored. `TriageReport`
carries them for exactly this reason: two contributors measuring with
`text_min=200` and `text_min=350` are running *different conditions*, and a
triage row without the thresholds is two measurements wearing one label.
Unlike `tool_version`, absence here is an **error**, not "unrecorded" — the
requirement lands before any triage row exists, so there is no legacy to
grandfather. Non-triage rows omit both keys. Aggregation/grouping over triage
rows MUST include both values in the grouping key.

### 3.1 `doc_type` vocabulary

`doc_type` is the **corpus class** field: what kind of document was measured.
It is free-form `String` by design, so the vocabulary grows by adding *values*,
never by changing the tuple's shape — every existing row keeps decoding.

| Value | Meaning |
|-------|---------|
| `math_pdf` / `math_compiled` | formula-bearing documents (LaTeX-compiled reference available) |
| `scanned_doc` | scanned, image-only page; no text layer (canonical term for scanned material) |
| `gov_doc` | official/form-like documents |
| `screenshot` | screen capture |
| `multicolumn_scan` | scanned multi-column page — reading order is the hard part |
| `tabular_doc` | table-dominant document |

The last two exist for document-assembly engines (see
`docs/superpowers/specs/2026-07-28-document-assembly-engines.md` §5.2). Note
what they are **not**: they are not a query axis. What a *caller asks for* lives
in `WorkloadSpec.documentClass`; the tuple records what was **measured**. Keeping
those apart is why document-class never became a tuple field.

## Row format (evidence tables, future results ingestion)

```json
{
  "estimand": "speed.ms_per_page",
  "value": 1981,
  "condition": {"model": "glm-ocr", "quant": "8bit", "dpi": 100,
                "doc_type": "math_compiled", "platform": "mlx",
                "hardware": "M5 Max 128GB", "instrument": "6af8919"},
  "tier": "T2",
  "source": "phase-1 pilot 2026-05, mcs.pdf pp.196–200",
  "caveat": "MLX rows provisional — see article1 reproducibility warning"
}
```

## Hard rules

1. No cross-tier mixing in a single ranking.
2. No cross-estimand arithmetic without a named, versioned formula.
3. Disagreeing numbers for the same question → surface both with labels.
4. Every `recommend` answer cites the evidence rows it used.
5. Thermal state matters: rows measured under throttle-suspect conditions
   carry a caveat (measureOCR records `ProcessInfo.thermalState`; the
   mac-benchmark sibling article shows why unmodelled throttle regimes
   corrupt naïve summaries).
