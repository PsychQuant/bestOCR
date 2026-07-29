# bestOCR

Evidence-based OCR recommendation for local VLMs on Apple Silicon — the OCR
sibling of bestASR. The product answers "which model / quant / DPI / platform
should I run for *this* document workload?" with numbers that trace back to a
pre-registered benchmark, never to vibes.

**Status: M4 — all four spec milestones shipped.** `bestocr run` executes any
of 13 engines (Apple Vision, tesseract, rapidocr/cnocr/surya via protocol-v1
Python adapters, Ollama VLMs, two *document-assembly* pipelines, and
Claude/OpenAI/Gemini cloud *reference* engines); `bestocr recommend` returns an evidence-labelled answer — a
tier-named ranking when measured rows exist (repo `evidence/rows.jsonl`,
or `~/.bestocr/evidence.jsonl` auto-fetched by the plugin wrapper for
installed users),
otherwise an honest *evidence-pending* capability filter (cloud engines are
never ranked). `bestocr compare` runs a local engine against a cloud
reference with a named metric (`quality.token_recall_vs_cloud@v1` — not
ground truth). `bestocr evidence ingest <run-id>` is the explicit gate that
promotes a runlog entry to T2 rows — run → ingest → RANKED recommend closes
the loop. Agents get the same via `bestocr-mcp` (eight tools incl. async job
polling; heavy OCR single-flighted). Spec:
`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`.

**One command to a deliverable** (`pipeline`): `bestocr pipeline scan.pdf --to
docx` runs normalize → route → OCR → assemble → convert and prints every stage.
It writes into its own `bestocr-out/` directory rather than beside the input, and
**refuses before doing any OCR** if an output already exists (pass `--overwrite`).
The converter is chosen by content — math-bearing markdown goes to pandoc for
native OMath equations, everything else to macdoc — and the choice is named in
the report so a fidelity complaint lands on the right project. The produced
`.docx` is structurally validated (a real ZIP carrying `word/document.xml`), not
assumed from an exit code. The same flow is the MCP `pipeline` tool, so
`/bestocr:ocr-to` is a thin shell over one call rather than a second
implementation of these rules.

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
engine (matched pairs only).

**Document assembly is a routed capability** (`doc.paddleocr-pipeline`,
`doc.marker`): per-page transcription cannot resolve multi-column reading
order, so `--document-class multi-column|tabular|mixed` restricts candidates to
engines that assemble, and prints what that costs (both are much slower than the
per-page path). Results carry an optional `document` structure whose block order
*is* the reading order. The two fidelity estimands
(`quality.reading_order_tau@v1`, `quality.table_structure_f1@v1`) are **defined
with formulas and deliberately unmeasured** — they need a human-annotated
reference subset built from redistributable material, which does not exist yet,
so `recommend` keeps answering *evidence-pending* for them. Design:
`docs/superpowers/specs/2026-07-28-document-assembly-engines.md`. Backlog:
that annotated subset, text-layer-aware PDF shortcut, MLX serving path
(upstream).

## Install for AI agents (Claude Code)

This repo doubles as a Claude Code plugin marketplace. Installing the plugin
gives an agent the **MCP server** (`bestocr-mcp`, a notarized binary
auto-downloaded on first use):

```bash
claude plugin marketplace add PsychQuant/bestOCR
claude plugin install bestocr@bestocr
```

MCP tools: `ocr` (sync, or `async: true` → `job_id`), `pipeline` (input →
deliverable file), `consensus`, `recommend`, `list_engines`, `list_models`,
`ocr_status`, `ocr_result` (long-poll). The
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

Building from source needs **Swift 6.3 or newer** — a transitive `mlx-swift`
dependency declares that floor. If `swift build` fails with

```
error: 'mlx-swift': package 'mlx-swift' @ <ver> is using Swift tools version
       6.3.0 but the installed version is <older>
```

the usual cause is not a missing toolchain but a **shadowed** one: a version
manager such as [swiftly](https://swiftlang.github.io/swiftly/) puts its shim
ahead of `/usr/bin` in `PATH`, so `swift` resolves to its default toolchain
rather than Xcode's. Check with `type -a swift` — if two entries appear, the
first one wins and it may be the older one. The repo ships a `.swift-version`
pinning the `xcode` toolchain, which resolves this for swiftly users; if you
use a different manager, select a 6.3+ toolchain yourself. `xcrun swift build`
is a quick way to confirm the Xcode toolchain builds cleanly.

## Usage

```bash
bestocr list-engines                            # probe table + install hints
bestocr pipeline scan.pdf --to docx --doc-type scanned_doc   # input → deliverable
bestocr run paper.pdf --doc-type math_pdf --math   # auto-routed
bestocr run page.png --engine vision --doc-type screenshot
bestocr run paper.pdf --engine vlm.glm-ocr --dpi 150 --pages 1-3 \
    --doc-type math_pdf --out out/
bestocr recommend --doc-type math_pdf --math --priority quality
bestocr run scan.pdf --doc-type multicolumn_scan --document-class multi-column
bestocr compare page.png --engine vision --vs cloud.claude
bestocr consensus scan.pdf --doc-type gov_doc   # multi-engine CCT adjudication
bestocr evidence ingest <run-id>                # runlog → T2 rows (explicit gate)
```

`consensus` runs ≥2 local engines over the same input, aligns items
(line-primary, table cells split), and adjudicates disagreements with a
**pluggable adjudicator** (`--adjudicator`, default `ds-lite`): six models ship
— `ds-lite`, `majority` (the control), `ds-full` (character-level directional
confusion), `prior-weighted` (competence prior from measured T2 `word_recall`
rows), `irt` (per-item difficulty + per-engine ability), and `rover` (confusion
network; insertions/deletions representable). `--list-adjudicators` prints them
as labelled tradeoffs, never a ranking — a single ordering would imply they
measure the same thing. Consensus quantities are estimand-qualified per
adjudicator (`consensus.<id>.<quantity>@v1`), so two models' numbers can never
be cross-ranked. The default path: consensus transcript (`<stem>.consensus.md`, ⚠
marks low-consensus items) + per-engine per-kind competence and a
low-consensus review list (`<stem>.consensus.json`). Consensus is not ground
truth — the report's `agreement` matrix surfaces inter-engine error
correlation as a diagnostic, and the "-lite" estimator has no confusion
matrix (no directional error discrimination). Local engines only; runs get
a runlog entry whose distinct estimands (`speed.ensemble_ms_per_page@v1`)
never mix into single-engine rankings. MCP tool: `consensus` (supports
`async=true`).

Engine ids: `vision`, `tesseract`, `ext.rapidocr`, `ext.cnocr`, `ext.surya`,
`vlm.glm-ocr`, `vlm.ovisocr2`, `vlm.paddleocr-vl`, `doc.paddleocr-pipeline`,
`doc.marker`, `cloud.claude`, `cloud.openai`, `cloud.gemini`. The two `doc.*`
engines need Python tooling (`paddleocr`+`paddlepaddle`+`paddlex[ocr]`, or
`uv tool install marker-pdf`) and are probe-gated with install hints;
`list-engines` prints each one's honest tradeoff next to it. VLM engines need a running `ollama serve`;
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
