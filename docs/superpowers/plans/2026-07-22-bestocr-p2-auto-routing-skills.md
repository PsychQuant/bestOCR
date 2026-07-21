# bestOCR P2 — Auto-Routing + Fallback Chain + Workflow Skills

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the backlog items that make bestOCR a true measured router: `--engine auto` (recommend-driven selection, now the default), the fallback chain (spec §8, deferred since M1), and the plugin workflow skills (`/bestocr:ocr`, `/bestocr:compare`, `/bestocr:evidence-ingest`) — completing bestASR four-piece parity.

**Architecture:** `AutoRouter` reuses `Recommender` verbatim (same ordering, same tier discipline) and adds probe-filtering; `RunPipeline.executeAuto` walks the candidate list, records every failed attempt, succeeds on the first working engine. Explicit `--engine <id>` keeps no-fallback semantics (the user chose). Skills are orchestration-only markdown (no engine logic), bestASR pattern.

## Global Constraints

- All M1–M4 constraints hold. `set -o pipefail` on verification chains.
- Auto-selection = `Recommender.recommend(...)` entry order (ranked or capability-filtered — the honest split is preserved and *reported*); cloud engines never auto-selected (already excluded by Recommender).
- Fallback only in auto mode; every fallback hop is visible in output ("fallback: X failed (reason) → Y"). All-fail = loud error listing every attempt.
- CLI `run` keeps `--engine` but it becomes optional with default `auto`; new `--priority` / `--math` flags feed the workload spec. MCP `ocr` tool: `engine` optional → auto.
- Skills: instructions only; shell out to `bestocr` CLI / call MCP tools; never re-implement logic.
- Branch protection now requires linear history — merge via fast-forward as before.

---

### Task 1: AutoRouter (Kit)

**Files:** Create `Sources/BestOCRKit/Recommend/AutoRouter.swift`; Test `Tests/BestOCRKitTests/AutoRouterTests.swift`.

**Interfaces:** `AutoRouter.Selection { candidateIDs: [String]; mode: Recommendation.Mode }`; `AutoRouter.candidates(docType:languages:priority:needsMath:registry:evidence:) -> Selection` — Recommender entry order, minus engines whose note marks them unrankable? No: keep ALL entries (ranked first, then unverified) — fallback wants the full capability-filtered list.

Tests: with T2 rows → ranked engine first, unverified after, cloud absent; with no rows → capability order; empty candidates → empty selection.

### Task 2: RunPipeline.executeAuto (Kit)

**Files:** Modify `Sources/BestOCRKit/RunPipeline.swift`; Test additions in `Tests/BestOCRKitTests/RunPipelineTests.swift`.

**Interfaces:** `RunSummary` gains `attempts: [Attempt]` (`Attempt { engineID: String; failure: String? }` — last attempt has `failure == nil` on success); `RunPipeline.executeAuto(inputPath:dpi:pageSpec:languages:docType:priority:needsMath:outDir:registry:evidence:runLog:) async throws -> RunSummary`. Existing `execute` keeps single-engine semantics and returns `attempts == [Attempt(engineID, nil)]`.

Behavior: candidates from AutoRouter → skip probe-unavailable (recorded as attempts with failure="unavailable: …") → recognize; on throw record and continue; success → write outputs (same as execute); all failed → `OCREngineError` message enumerating attempts.

Tests (stub engines): first-fails-second-succeeds fallback with attempts recorded; unavailable engines skipped; all-fail error lists every engine; ranked-first ordering respected (stub evidence rows).

### Task 3: CLI + MCP wiring

**Files:** Modify `Sources/bestocr/RunCommand.swift` (`--engine` optional default "auto"; add `--priority`, `--math`; print fallback trail), `Sources/BestOCRMCPCore/Server.swift` (ocr tool: `engine` optional → auto path; schema description updated; add `priority`/`math` args), tests in `ServerTests` (ocr without engine on stub registry succeeds via auto).

Smoke: `bestocr run /tmp/bestocr-smoke.png --doc-type screenshot` (no --engine) → auto picks vision (T2 row from earlier ingest, priority default balanced → falls to capability order; either way vision first among available) and prints the routing line.

### Task 4: Workflow skills + plugin bump

**Files:** Create `plugins/bestocr/skills/ocr/SKILL.md`, `plugins/bestocr/skills/compare/SKILL.md`, `plugins/bestocr/skills/evidence-ingest/SKILL.md` (bestASR skill format: frontmatter `name`/`description` + CLI/MCP orchestration steps); bump `plugin.json` + `marketplace.json` to 0.4.0.

### Task 5: Release v0.4.0 + docs

- `make release-signed` → `gh release create v0.4.0` (binaries changed: auto-routing in CLI + MCP).
- README (auto default, fallback, skills), CLAUDE.md backlog update, changelog `20260722_p2-auto-routing-skills.md`.
- Full suite + marketplace update (`claude plugin marketplace update bestocr` + `claude plugin update bestocr@bestocr`).

## Self-Review

- Spec §7 Flow B "auto 路由(查 evidence)" and §8 fallback chain now implemented; §7 Flow A skills complete the four-piece. Explicit-engine no-fallback is a deliberate semantic (user override wins).
- Types: `Attempt` nested in `RunSummary`; `executeAuto` reuses `execute`'s output-writing path (extract shared private helper to avoid divergence).
- Remaining backlog after P2: quality-estimand ingest, math-delimiter normalization (recorded in README).
