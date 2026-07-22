# bestOCR

Evidence-based OCR recommendation for local VLMs on Apple Silicon — the OCR
sibling of bestASR. The product answers "which model / quant / DPI / platform
should I run for *this* document workload?" with numbers that trace back to a
pre-registered benchmark, never to vibes.

**Status: M4 — all four spec milestones shipped.** `bestocr run` executes any
of 11 engines (Apple Vision, tesseract, rapidocr/cnocr/surya via protocol-v1
Python adapters, Ollama VLMs, and Claude/OpenAI/Gemini cloud *reference*
engines); `bestocr recommend` returns an evidence-labelled answer — a
tier-named ranking when measured rows exist in `evidence/rows.jsonl`,
otherwise an honest *evidence-pending* capability filter (cloud engines are
never ranked). `bestocr compare` runs a local engine against a cloud
reference with a named metric (`quality.token_recall_vs_cloud@v1` — not
ground truth). `bestocr evidence ingest <run-id>` is the explicit gate that
promotes a runlog entry to T2 rows — run → ingest → RANKED recommend closes
the loop. Agents get the same via `bestocr-mcp` (six tools incl. async job
polling; heavy OCR single-flighted). Spec:
`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`.

**Auto-routing is the default** (v0.4.0): `bestocr run doc.pdf` picks the
engine from the recommend ordering (measured rows first, capability filter
otherwise) and falls back past unavailable/failing engines — every hop is
printed, never silent. Pin an engine with `--engine <id>` (no fallback).
Workflow skills ship with the plugin: `/bestocr:ocr`, `/bestocr:ocr-to`
(OCR → target file format, v1 docx), `/bestocr:compare`,
`/bestocr:evidence-ingest`. `ocr-to` picks its converter by content:
math-bearing markdown goes through pandoc when available (native OMath
equations in the docx), macdoc otherwise (literal LaTeX, disclosed).
`compare` runs are logged with their
`quality.token_recall_vs_cloud@v1` score attached, so `evidence ingest`
promotes speed **and** quality rows; `recommend --priority quality` falls
back to that metric only when no `word_recall` rows exist (never blended).
PaddleOCR-VL's `\( \)` math delimiters are normalized to `$`/`$$` at the
engine (matched pairs only). Backlog: text-layer-aware PDF shortcut, MLX
serving path (upstream).

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

## CLI install

```bash
# Option A — notarized release binary (no Swift toolchain needed; arm64,
# Developer ID signed + Apple notarized so Gatekeeper is happy)
mkdir -p ~/bin
curl -sL -o ~/bin/bestocr \
  https://github.com/PsychQuant/bestOCR/releases/latest/download/bestocr
chmod +x ~/bin/bestocr
# verify against the .sha256 sidecar published with every release:
curl -sL https://github.com/PsychQuant/bestOCR/releases/latest/download/bestocr.sha256
shasum -a 256 ~/bin/bestocr

# Option B — build from source
swift build -c release   # binary at .build/release/bestocr
```

## Usage

```bash
bestocr list-engines                            # probe table + install hints
bestocr run paper.pdf --doc-type math_pdf --math   # auto-routed
bestocr run page.png --engine vision --doc-type screenshot
bestocr run paper.pdf --engine vlm.glm-ocr --dpi 150 --pages 1-3 \
    --doc-type math_pdf --out out/
bestocr recommend --doc-type math_pdf --math --priority quality
bestocr compare page.png --engine vision --vs cloud.claude
bestocr consensus scan.pdf --doc-type gov_doc   # multi-engine CCT adjudication
bestocr evidence ingest <run-id>                # runlog → T2 rows (explicit gate)
```

`consensus` runs ≥2 local engines over the same input, aligns items
(line-primary, table cells split), and adjudicates disagreements with a
Dawid-Skene-lite estimator: consensus transcript (`<stem>.consensus.md`, ⚠
marks low-consensus items) + per-engine per-kind competence and a
low-consensus review list (`<stem>.consensus.json`). Consensus is not ground
truth — the report's `agreement` matrix surfaces inter-engine error
correlation as a diagnostic, and the "-lite" estimator has no confusion
matrix (no directional error discrimination). Local engines only; runs get
a runlog entry whose distinct estimands (`speed.ensemble_ms_per_page@v1`)
never mix into single-engine rankings. MCP tool: `consensus` (supports
`async=true`).

Engine ids: `vision`, `tesseract`, `ext.rapidocr`, `ext.cnocr`, `ext.surya`,
`vlm.glm-ocr`, `vlm.ovisocr2`, `vlm.paddleocr-vl`, `cloud.claude`,
`cloud.openai`, `cloud.gemini`. VLM engines need a running `ollama serve`;
defaults are the SHA256-pinned `-anova:q8_0` builds, `--model` overrides.
Cloud engines are probe-gated by `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` /
`GEMINI_API_KEY` (documents leave the machine — reference tier only; model
defaults override via `BESTOCR_{CLAUDE,OPENAI,GEMINI}_MODEL`). nougat is
deferred: its local install is stranded in a pipx venv and upstream is
archived — the adapter protocol makes re-admission a script-drop when wanted.

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
