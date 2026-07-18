# bestOCR

Evidence-based OCR recommendation for local VLMs on Apple Silicon — the OCR
sibling of bestASR. The product answers "which model / quant / DPI / platform
should I run for *this* document workload?" with numbers that trace back to a
pre-registered benchmark, never to vibes.

**Status: scaffold.** The instrument (measureOCR) is production-ready and
pinned by article 1; the recommendation layer ships only after the
pre-registered sweep produces real evidence. `recommend` before that returns
an honest *evidence-pending* answer, not a guess.

## Architecture — where OCR capability actually lives

```
PsychQuant/ocr-swift          ← shared capability layer (published SPM package)
        │                        MLX + Ollama backends, PDFKit extractor
   ┌────┴─────────────┐
   │                  │
macdoc                bestOCR (this repo)
PDF/document tools    ├── repos/measureOCR   ← instrument: factorial benchmark CLI
(pdf-to-latex,        │                        + ANOVA harness (article 1 pins it)
 macdoc ocr, …)       ├── evidence/          ← benchmark results with provenance labels
                      └── (future) mcp/      ← recommender MCP server (bestasr pattern)
```

Both consumers pull `ocr-swift` from GitHub as a versioned package — moving
measureOCR out of macdoc changed **zero** build dependencies. macdoc's PDF
tools keep their OCR capability untouched.

## Layout

```
repos/measureOCR      git submodule → github.com/PsychQuant/measureOCR
                      (formerly macdoc/cli/FastOCR; see docs/migration-2026-07-18.md)
evidence/
  schema.md           the three-tier evidence-labelling contract (read this first)
  candidates.json     candidate model inventory with source-tier labels
docs/
  migration-2026-07-18.md   how and why measureOCR moved here
```

## Evidence discipline (the core design constraint)

Every number a future `recommend` returns carries a three-part label —
**estimand × condition × provenance tier** — per `evidence/schema.md`.
Numbers from different fits, conditions, or tiers are never averaged or
silently mixed. This rule is imported wholesale from the mac-benchmark
manuscript's estimand-labelling lessons (kiki830621/mac-benchmark #18–#21),
where unlabelled shares (25% vs 17.7% vs 7% — same phenomenon, different
estimand/fit) nearly shipped as contradictions.

## Planned interface (bestasr pattern)

| Tool | Contract |
|------|----------|
| `list_models` | candidate inventory + evidence tier per entry |
| `list_backends` | ollama / omlx / mlx-swift health probe |
| `recommend` | evidence-labelled ranking for a workload spec; *evidence-pending* until the sweep lands |
| `run` | delegate to `measureocr` for on-machine measurement |

## Relationship to article 1

`article1-vlm-ocr-anova` (in `~/Academic/projects/active/local-llm-benchmarking/`)
pins `repos/measureOCR` at commit `3f8f5ab` as its measurement instrument. The
pre-registered sweep's `results.tsv` is the founding tier-1 evidence for
`recommend`. Instrument changes after the OSF freeze require a new pin + a
pre-registration deviation note on the article side.
