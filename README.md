# bestOCR

Evidence-based OCR recommendation for local VLMs on Apple Silicon — the OCR
sibling of bestASR. The product answers "which model / quant / DPI / platform
should I run for *this* document workload?" with numbers that trace back to a
pre-registered benchmark, never to vibes.

**Status: M3 — MCP server + plugin.** `bestocr run` executes any locally
available engine (Apple Vision, tesseract, rapidocr/cnocr/surya via
protocol-v1 Python adapters, Ollama VLMs); `bestocr recommend` returns an
evidence-labelled answer — a tier-named ranking when measured rows exist in
`evidence/rows.jsonl`, otherwise an honest *evidence-pending* capability
filter. Agents get the same via `bestocr-mcp` (six tools incl. async job
polling; heavy OCR single-flighted). Every run records the full evidence
condition tuple to `~/.bestocr/runlog.jsonl`. Cloud reference + `evidence
ingest` land in M4 (see
`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`).

## Install for AI agents (Claude Code)

This repo doubles as a Claude Code plugin marketplace. Installing the plugin
gives an agent the **MCP server** (`bestocr-mcp`, a notarized binary
auto-downloaded on first use):

```bash
claude plugin marketplace add PsychQuant/bestOCR
claude plugin install bestocr@bestocr
```

MCP tools: `ocr` (sync, or `async: true` → `job_id`), `recommend`,
`list_engines`, `list_models`, `ocr_status`, `ocr_result` (long-poll). The
server process persists across calls; VLM warmth lives in the local Ollama
server (`keep_alive`), and concurrent heavy OCR is serialized so the model
server and Python tools are never overloaded.

## Release (maintainer)

```bash
make release-signed     # build + Developer ID sign + notarize + sha256
gh release create v<semver> .build/release/bestocr-mcp .build/release/bestocr \
    .build/release/*.sha256
```

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
Sources/BestOCRKit    engine layer: OCREngine protocol, engines, router pipeline
Sources/bestocr       CLI (thin shell over BestOCRKit)
Tests/BestOCRKitTests Swift Testing suite (programmatic fixtures, no binaries)
evidence/
  schema.md           the three-tier evidence-labelling contract (read this first)
  candidates.json     candidate model inventory with source-tier labels
docs/
  migration-2026-07-18.md   how and why measureOCR moved here
```

## Usage (M1)

```bash
swift build -c release
.build/release/bestocr list-engines             # probe table + install hints
.build/release/bestocr run page.png --engine vision --doc-type screenshot
.build/release/bestocr run paper.pdf --engine vlm.glm-ocr --dpi 150 --pages 1-3 \
    --doc-type math_pdf --out out/
.build/release/bestocr recommend --doc-type math_pdf --math --priority quality
```

Engine ids: `vision`, `tesseract`, `ext.rapidocr`, `ext.cnocr`, `ext.surya`,
`vlm.glm-ocr`, `vlm.ovisocr2`, `vlm.paddleocr-vl` (VLM engines need a running
`ollama serve`; defaults are the SHA256-pinned `-anova:q8_0` builds, `--model`
overrides). nougat is deferred: its local install is stranded in a pipx venv
and upstream is archived — the adapter protocol makes re-admission a
script-drop when wanted.

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
