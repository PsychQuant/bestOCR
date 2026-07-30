# bestOCR-bench — externalizing the public evidence layer (design spec)

- **Date**: 2026-07-30
- **Status**: proposed — **implementation deliberately deferred** per #33's own
  timing clause (P3; start when evidence volume or an external contributor
  makes it worth it). This spec pre-settles the decisions so that day is
  unblocked; it does not move the day forward.
- **Issue**: #33
- **Reference model**: `PsychQuant/bestASR-bench` (inspected 2026-07-30:
  `corpus/` + `measurements/` + `LEADERBOARD.md` + `SUBMISSION_FORMAT.md` +
  `tools/` CI validators + 3×MAD soft outlier flags).

## 1. Division of labor (the one-sentence contract)

**bestOCR keeps the instrument and the local evidence loop; bestOCR-bench takes
public, cross-machine aggregation.** Nothing about the local loop changes:
`bestocr run` → runlog → explicit `evidence ingest` → T2 rows → `recommend`.
The bench repo is *additive* — the same division bestASR already lives with,
making the two projects symmetric.

Hard boundary, restated from the issue: **`repos/measureOCR` (❄️ article-1
frozen instrument) is untouched and unrenamed.** The bench is "add", never
"change"; methodology changes still require a deviation note under the existing
freeze discipline.

## 2. What moves, what stays, what is mirrored

| Artifact | Canonical home | Rationale |
|---|---|---|
| `evidence/schema.md` (labelling contract) | **bestOCR** | Code depends on it (`Estimand.canonical`, tuple shape, tier rules); the tests that pin it live here. The bench repo **vendors a copy** with a banner naming the canonical home — a contract the validator enforces must be readable where submissions happen, but it must not fork |
| `evidence/rows.jsonl` (maintainer-curated T2 rows) | **bestOCR** | This is the instrument's own measurement record and what `committedEvidenceRowsStillDecode` pins. It does not migrate |
| `evidence/candidates.json` | **bestOCR** | Engine-admission bookkeeping is instrument-side |
| Public cross-machine measurements | **bench** `measurements/` | New — does not exist today |
| Redistributable corpus + reference annotations | **bench** `corpus/` | New — see §5 |
| Leaderboard / submission format / CI validators | **bench** | New |

Consequence: **no file leaves bestOCR.** "外放" externalizes the *layer*, not
the existing files — the issue's Expected already says the local loop stays.

## 3. Row contract — bestASR-bench's skeleton, bestOCR's discipline

bestASR-bench's mechanics port directly: append-only JSONL, one file per
submission (`measurements/<UTC-basic>-<contributor>-<machine12>.jsonl`),
denormalized self-sufficient rows, CI hard checks (schema / ranges / corpus
existence / dedup) plus 3×MAD **soft** outlier flags for human review.

What must NOT be ported unchanged is the row shape. bestOCR's evidence
discipline is stricter than a metric row: every number carries
**estimand × condition tuple × provenance tier**, and hard rules 1/2 forbid
cross-tier and cross-estimand mixing. The bench row is therefore the
`EvidenceRow` shape itself, snake_case, plus submission fields:

```json
{"estimand": "speed.ms_per_page@v1", "value": 1981,
 "condition": {"model": "glm-ocr", "quant": "q8_0", "dpi": 150,
               "doc_type": "scanned_doc", "platform": "ollama",
               "hardware": "Apple M4 Max 128GB", "instrument": "bestocr 0.9.0",
               "tool_version": null},
 "tier": "T2-community", "source": "bench:<submission-file>#<line>",
 "caveat": null,
 "contributor": "github-handle", "machine_id": "<12>", "measured_at": "…Z",
 "corpus_id": "<sha>"}
```

- `corpus_id` must exist in `corpus/manifest.jsonl` — only measurements against
  the canonical corpus are comparable (bestASR-bench rule, ported verbatim).
- **`condition.tool_version` (#28) is load-bearing here**: cross-machine rows
  from adapter-backed engines are incomparable across tool generations, and the
  field that records this shipped in v0.8.1 precisely so a public layer would
  not be born blind. CI warns when an `ext.*`/`doc.*` row omits it.
- Estimand names are validated against the schema's versioned vocabulary;
  unknown estimands are rejected, not silently admitted (hard rule 2 at the
  gate, not in the reader).

## 4. Provenance — the decision this spec exists to make

T2 means "measured on **our** hardware by **our** instrument". Community
submissions are neither T2 nor vendor-T3. Decision:

- Bench rows carry tier **`T2-community`**: measured by the released,
  version-named instrument (`condition.instrument`), on hardware we do not
  control, attested by the contributor. It is a *new label*, not a redefinition
  of an old one — T2 keeps meaning what every committed row already means.
- **The leaderboard ranks within `T2-community` only**, per estimand, per
  condition-compatible group. Maintainer T2 rows may be displayed alongside as
  labelled reference points, never merged into one ranking (hard rule 1).
- **bestOCR's own `recommend` does not consume bench rows in v1.** The plugin
  wrapper keeps fetching the maintainer-curated `evidence/rows.jsonl` from
  bestOCR. Importing community aggregates into local routing is a separate,
  explicit future decision — if ever — with its own tier treatment. This is the
  wall that keeps a mislabelled community number from silently steering
  someone's auto-routing.

## 5. Corpus — license gate ported, plus the convergence point

- License gate ported from bestASR-bench verbatim: manifest rows require
  `license ∈ {CC0, CC-BY, CC-BY-SA, public-domain, own-consented}` +
  attribution; page-image bodies live in a HF dataset (`bestocr-corpus`), the
  repo stores hashes and metadata only; corpus PRs get mechanical CI plus human
  license review.
- **The #15 exam corpus is excluded by construction** — third-party material,
  already established as non-redistributable. CI cannot check what it cannot
  see, so the submission doc states the rule and human review enforces it.
- **Convergence**: the human-annotated reference subset that
  `quality.reading_order_tau@v1` / `quality.table_structure_f1@v1` are blocked
  on (#16 spec §12, the repo's largest open item) is exactly what
  `corpus/` + reference annotations would hold. Building the bench corpus and
  unblocking the assembly estimands are **the same act of work**. This spec
  records the identity so the two backlog items are not staffed twice.

## 6. Non-goals (v1)

- No repo creation, no migration, no CI authoring **now** — §7's gate governs.
- No change to `EvidenceStore`'s resolution chain (env → CWD → `~/.bestocr`).
- No `recommend` consumption of bench aggregates (see §4).
- No touching `repos/measureOCR`.
- No submission tooling inside `bestocr` CLI yet (`bestocr bench submit` à la
  bestASR is natural but belongs to the build-out phase).

## 7. Phasing — gated by the issue's own trigger, not by this spec

| Phase | Content | Gate |
|---|---|---|
| 0 (this PR) | This spec | review |
| 1 | Create `PsychQuant/bestOCR-bench` skeleton (README, SUBMISSION_FORMAT, vendored schema copy, empty corpus/measurements, CI validators) | **#33's trigger clause: evidence volume or an external contributor.** The spec existing does not advance the date |
| 2 | First corpus: the redistributable annotated subset (§5 convergence) | phase 1 + annotation effort (own honesty problem, per #16 §12) |
| 3 | `bestocr bench submit` tooling; leaderboard automation | phase 1–2 + demand |
| 4 | Any `recommend` relationship to bench aggregates | separate decision, separate spec |

Security baseline for the new repo at phase 1 follows the existing
first-release audit gate (`macdoc/scripts/audit-security.sh`) before any tag.

## 8. Open questions (deferred with the build-out, not blockers to this spec)

- Whether `T2-community` should subdivide by attestation strength (e.g. rows
  produced by the notarized release binary vs source builds) — the
  `instrument` field already records the version string; whether it is enough
  is an empirical question for real submissions.
- Machine identity (bestASR uses a `machine_id` hash + denormalized chip/RAM
  fields) — port as-is or thin it; decide against real contributor friction.
- LEADERBOARD grouping for OCR's higher-dimensional condition tuple (doc_type ×
  dpi × quant × tool_version is wider than ASR's axes) — likely per-estimand
  tables with explicit condition columns rather than bestASR's flatter view.
