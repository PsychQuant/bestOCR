# bestOCR multi-platform integration — design spec

- **Date**: 2026-07-21
- **Status**: approved in brainstorming dialogue (§1–§3 explicitly; §4 compact form); pending user review of this document
- **Decision**: Approach A — bestASR-isomorphic `BestOCRKit` grown inside this repo

## 1. Context and motivation

bestOCR today is a scaffold: an evidence schema, a candidate inventory, and the
frozen instrument (`repos/measureOCR`, pinned by article 1 at `3f8f5ab`). The
only runnable OCR paths are the ocr-swift VLM backends (Ollama primary; MLX
blocked upstream). Meanwhile the machine carries unconnected OCR capability:
tesseract (+ tesseract-lang), Apple Vision framework, and Python tools
(surya-ocr 0.17.1, nougat-ocr 0.1.17, rapidocr 3.6.0, cnocr 2.3.2.2).

The user's requirement: **deep integration — bestOCR must call many models
across many platforms**, at full bestASR parity: a practical daily router *and*
an instrument-compatible measurement substrate, exposed through all four
surfaces (CLI + MCP server + Claude plugin + workflow skills).

## 2. Requirements (from brainstorming Q&A)

| Axis | Decision |
|------|----------|
| Purpose | Both: practical router now, factorial-measurable backends for evidence accumulation |
| Platform scope | **Local is the core**: local VLM (Ollama/MLX) + local classical OCR (Vision, tesseract, Python tools). **Cloud LLM vision is a quality reference baseline** — important as a standard to compare against, never part of local ranking |
| Surfaces | Four-piece parity with bestASR: CLI, MCP server, plugin marketplace, workflow skills |
| Workloads | All four: math/academic PDFs, scanned books/archive docs, screenshots, zh/ja mixed-script documents |
| Evidence discipline | `evidence/schema.md` three-tier contract holds unchanged; `recommend` stays honest (*evidence-pending*) until measured rows exist |
| Dual flows | Flow A: agent-orchestrated (plugin/skill/MCP). Flow B: human-direct CLI with zero agent dependency. Both first-class |

## 3. Non-goals

- No change to `repos/measureOCR` (article 1 freeze; instrument stays pinned).
- No cloud engines in `recommend` rankings (reference column only).
- No automatic promotion of run logs into `evidence/` (explicit ingest only).
- PP-OCR classical pipeline stays excluded from the VLM factorial (per
  candidates.json); it may appear later as a *non-VLM baseline engine* for
  daily routing, which is a different role than a factorial level.

## 4. Architecture (Approach A)

```
bestOCR/
  Sources/
    BestOCRKit/            engine layer: OCREngine protocol, Router, Recommend,
      Engines/             RunLog, EvidenceStore reader
        VLMEngine          wraps ocr-swift (Ollama primary; MLX when unblocked)
        VisionEngine       Apple Vision framework, in-process, zero-dependency
        TesseractEngine    subprocess over brew tesseract (+ tesseract-lang)
        ExternalProcessEngine  bestASR external-engine protocol v1 (JSON over
                           stdout); one venv per Python tool
        CloudReferenceEngine   OpenAI / Claude / Gemini vision over HTTPS;
                           reference-tier only
    bestocr/               CLI (thin shell over BestOCRKit)
    bestocr-mcp/           MCP server (links BestOCRKit; warm models)
  adapters/                Python adapter scripts + setup.sh per tool
  plugins/                 Claude plugin (marketplace in this repo, bestASR style)
  repos/measureOCR         instrument — frozen, untouched
  evidence/                evidence layer recommend reads (schema.md contract)
```

Rejected alternatives: (B) sinking engines into the shared `ocr-swift` package
— pollutes a package the frozen instrument depends on, and venv/cloud client
lifecycle does not belong in a capability SPM package; (C) Python-first
orchestrator — abandons the established Swift infra (notarize pipeline, MCP
warm-model pattern, plugin marketplace).

## 5. Engine layer

### 5.1 OCREngine protocol

```swift
public protocol OCREngine: Sendable {
    var id: String { get }                     // "vlm.glm-ocr", "vision", "ext.surya", …
    var family: EngineFamily { get }           // .localVLM / .classical / .cloudReference
    var capabilities: EngineCapabilities { get }
    func probe() async -> EngineAvailability   // installed? healthy? what is missing?
    func recognize(_ request: OCRRequest) async throws -> OCRResult
}
```

`EngineCapabilities` declares: accepted inputs (pdf-page image, raw image),
output level (plain text / markdown / math-aware markdown), language coverage,
network requirement, approximate memory class.

### 5.2 Input normalization

PDFs are rendered to page images by ocr-swift's `PageRenderer` at a caller-
specified DPI (the same DPI factor the instrument varies); raw images pass
through. **Engines only ever see a sequence of page images.** (Approved
explicitly — the cost that born-digital PDFs get re-OCRed was surfaced and
accepted; text-layer-aware shortcuts can be a later, separate feature.)

### 5.3 Output contract

`OCRResult` = per-page text/markdown + full metadata deliberately aligned with
the evidence-schema condition tuple:
`(model, quant, dpi, doc_type, platform, hardware, instrument_commit)` plus
per-page wall-clock and `ProcessInfo.thermalState`. Every daily run is thereby
potential T2 raw material — one explicit ingest step away from evidence, never
closer.

### 5.4 Engine families (initial roster)

| Engine | Integration | Strength / notes |
|--------|-------------|------------------|
| VLMEngine | ocr-swift backends; model profiles for GLM-OCR, OvisOCR2, PaddleOCR-VL | math PDFs, complex layout. Model quirks live in the profile — e.g. PaddleOCR-VL requires the native `OCR:` prompt (generic prompts yield degenerate loops) and emits `\( \)` math delimiters |
| VisionEngine | Vision framework, in-process | screenshots, quick single images; strong zh-Hant/ja |
| TesseractEngine | subprocess | scanned-book batches, low memory |
| ExternalProcessEngine × {surya, nougat, rapidocr, cnocr} | protocol v1 JSON, one venv each | nougat = math; cnocr = Chinese; upstream churn breaks only the adapter, never the host |
| CloudReferenceEngine × {OpenAI, Claude, Gemini} | HTTPS | **reference only**: comparison and proofreading aid; never ranked with local engines |

## 6. Routing, recommend, and the evidence flow

```
input (PDF/image) ─► PageRenderer ─► Router ─► engine choice
                                                │ explicit --engine → run it
                                                │ auto → consult evidence/
                                                │ compare → local vs cloud side-by-side
                                                ▼
                                            OCRResult
                                     ┌──────────┴──────────┐
                                     ▼                     ▼
                                 user output          run log (local)
                                              ── explicit ingest ──► evidence/ (T2)
```

### 6.1 recommend behaviour

1. **With evidence**: rank only within matching condition tuples, never mix
   tiers in one ranking, name the tier, cite the rows used (schema.md hard
   rules 1 and 4).
2. **Without evidence**: degrade honestly to **capability filtering** — "no
   measured data for this workload; by declared capabilities the candidates
   are X/Y/Z (unverified)". Ranking and filtering are different speech acts
   and the answer always states which one it is.
3. **Cloud**: always in a separate *reference* column (T3 or a compare
   result), never in the ranking.

### 6.2 Run log → evidence promotion

Every run writes a local log row (full condition tuple + timing + thermal
state). Nothing auto-promotes. `bestocr evidence ingest <run-id>` is the
explicit, human-gated step that labels selected rows T2 and writes them into
`evidence/`. T1 remains exclusively the pre-registered sweep's `results.tsv`.
Rationale: daily-run conditions are uncontrolled (background load, thermal);
auto-promotion would pollute T2.

## 7. Surfaces — two first-class flows

### Flow A: agent-orchestrated (plugin / skills / MCP)

- `claude plugin install bestocr@bestocr` → MCP server + skills in one step.
- MCP tools: `ocr` (sync, or `async: true` → `job_id`), `recommend`,
  `list_engines`, `list_models`, `ocr_status`, `ocr_result` (long-poll).
- Engines link inside the MCP process → models stay warm across calls.
- Skills (orchestration only, no engine logic): `/bestocr:ocr` (any source →
  markdown, auto-routed), `/bestocr:compare` (local vs cloud reference),
  `/bestocr:evidence-ingest` (gated T2 promotion).

### Flow B: human-direct CLI (zero agent dependency)

```bash
bestocr run paper.pdf --out out/            # auto route (consults evidence)
bestocr run scan.pdf --engine tesseract     # explicit engine
bestocr recommend --doc-type math_pdf --lang zh-Hant --priority quality
bestocr list-engines                        # health-probe table + install hints
bestocr compare page.png --vs claude        # cloud reference comparison
bestocr evidence ingest <run-id>            # explicit T2 promotion
```

Both flows are thin shells over the same BestOCRKit router — behaviour is
identical by construction. Skills shell out to the CLI or call MCP tools;
they never reimplement engine logic.

## 8. Error handling

- **Probe before dispatch**: unavailable engine → clear message + install
  hint; never silently skipped.
- **External-process containment**: timeout per adapter call; non-zero exit
  surfaces stderr; protocol JSON is schema-validated; a broken venv disables
  exactly one engine.
- **Model quirks live in profiles**: PaddleOCR-VL native-prompt requirement
  and a degenerate-loop fuse (repeated n-gram detector aborts the generation)
  are encoded in the model profile, not at call sites.
- **Fallback chain**: in auto mode an engine failure falls through to the next
  capability-filtered candidate; every fallback is recorded in result
  metadata (bestASR "stable fallback").
- **Cloud**: missing API key → engine probes unavailable; local flow is never
  blocked by cloud configuration.

## 9. Testing (TDD, ≥80% coverage)

- **Unit**: protocol conformance per engine; ranking tier discipline (property:
  no ranking ever contains two tiers); output normalization; evidence-row
  parsing; capability filtering.
- **Integration**: each engine behind an availability guard — tool absent →
  test *skips* (visible), never fake-passes; golden-file tests on tiny
  fixtures per engine family.
- **E2E**: CLI run on fixture PDF + image per family; MCP round-trip incl.
  async job lifecycle.

## 10. Milestones

| # | Deliverable |
|---|-------------|
| M1 | BestOCRKit + OCREngine protocol + VisionEngine + TesseractEngine + VLMEngine(Ollama) + CLI `run`/`list-engines` |
| M2 | External-process adapters (surya/nougat/rapidocr/cnocr) + `recommend` with honest evidence-pending mode |
| M3 | MCP server (warm models, async jobs) + plugin marketplace + notarize pipeline |
| M4 | Cloud reference engines + `compare` + `evidence ingest` tooling |

## 11. Relationship to article 1

`repos/measureOCR` stays frozen at the article pin. BestOCRKit's engines are
designed to be factorial-measurable (condition tuple in every result), so a
*future* sweep can adopt them via a new instrument pin + pre-registration
deviation note — but nothing in this design touches the current instrument.

## 12. Open questions (deferred, not blockers)

- MLX serving path returns when upstream mlx-swift-lm regression is fixed
  (KNOWN-ISSUES #4); VLMEngine's backend enum already reserves the slot.
- granite-docling and Qwen-VL small variants remain T3 candidates; admitting
  them is an evidence decision, not an architecture change.
- Text-layer-aware PDF shortcut (skip OCR for born-digital pages) — explicitly
  deferred; revisit after M2.
