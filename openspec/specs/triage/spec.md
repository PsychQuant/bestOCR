# triage Specification

## Purpose

TBD - created by archiving change 'triage-single-entry'. Update Purpose after archive.

## Requirements

### Requirement: Per-page text-layer probe

The triage capability SHALL measure, for every page of a PDF input, the number of extractable text-layer characters (whitespace excluded), and SHALL classify each page as text-bearing when the count meets or exceeds the configured minimum (`BESTOCR_TRIAGE_TEXT_MIN`, default 200). Image inputs (png/jpg/tiff/heic/bmp) SHALL be classified as having no text layer without invoking the probe. The verdict SHALL be per-page; a file-level route is derived by aggregation and SHALL NOT overwrite per-page verdicts.

#### Scenario: Born-digital PDF

- **WHEN** every page of a PDF yields at least the configured minimum of text characters
- **THEN** the report marks all pages `has_text_layer: true` and the route is `text_direct`

#### Scenario: Scanned PDF

- **WHEN** every page yields fewer characters than the configured minimum
- **THEN** the route is `ocr_full`

#### Scenario: Hybrid document

- **WHEN** some pages carry a text layer and others do not
- **THEN** the route is `mixed` and `per_page_routes` maps every page to its own route; text-bearing pages are never routed to OCR and textless pages are never routed to `text_direct`

##### Example: three-page hybrid

- **GIVEN** page text-character counts [1834, 12, 1560] with `text_chars_min` = 200
- **WHEN** triage runs
- **THEN** `per_page_routes` is {"1": "text_direct", "2": "ocr_full", "3": "text_direct"} and `route` is `mixed`


<!-- @trace
source: triage-single-entry
updated: 2026-08-03
code:
  - Tests/BestOCRKitTests/TriageReportTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - Tests/BestOCRMCPCoreTests/ServerTests.swift
  - plugins/bestocr/.claude-plugin/plugin.json
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-debug/SKILL.md
  - changelog/20260803_p14-triage-single-entry.md
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - Sources/BestOCRKit/CoreTypes.swift
  - Sources/BestOCRKit/Triage/TriageDivergence.swift
  - evidence/schema.md
  - Tests/BestOCRKitTests/TriageProbeTests.swift
  - docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md
  - plugins/bestocr/skills/ocr/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-ask/SKILL.md
  - Sources/BestOCRKit/Triage/TriageRunner.swift
  - Tests/BestOCRKitTests/TriageRunTests.swift
  - .agents/skills/spectra-drift/SKILL.md
  - README.md
  - Sources/BestOCRKit/Triage/TriageProbe.swift
  - .spectra.yaml
  - Tests/BestOCRKitTests/TriageDivergenceTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .claude-plugin/marketplace.json
  - Sources/BestOCRKit/Triage/TriageReport.swift
  - Sources/bestocr/BestOCRMain.swift
  - .agents/skills/spectra-propose/SKILL.md
  - Sources/BestOCRMCPCore/Server.swift
  - Sources/bestocr/TriageCommand.swift
-->

---
### Requirement: Structure scan for suspect pages

For text-bearing pages, the triage capability SHALL compute a fragment ratio (proportion of 1–2 character tokens among all tokens on lines with more than 3 tokens) and SHALL flag a page as suspect when the ratio exceeds the configured maximum (`BESTOCR_TRIAGE_FRAG_MAX`, default 0.6). Suspect pages SHALL be listed in `suspect_pages` and routed to `render_suspect_pages`. Divergence measurement (when requested) reports per-page scores as evidence for the caller's own judgement; it SHALL NOT change routes (a clearing threshold would be a third uncalibrated constant — deliberately excluded until the annotated reference set exists).

#### Scenario: Formula page flagged

- **WHEN** a page's extracted text consists mostly of scattered 1–2 character tokens (the pdftotext signature of shredded mathematical notation)
- **THEN** the page appears in `suspect_pages` and its per-page route is `render_suspect_pages`

#### Scenario: Prose page passes

- **WHEN** a page's fragment ratio is at or below the configured maximum
- **THEN** the page is not listed in `suspect_pages` and its route is `text_direct`


<!-- @trace
source: triage-single-entry
updated: 2026-08-03
code:
  - Tests/BestOCRKitTests/TriageReportTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - Tests/BestOCRMCPCoreTests/ServerTests.swift
  - plugins/bestocr/.claude-plugin/plugin.json
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-debug/SKILL.md
  - changelog/20260803_p14-triage-single-entry.md
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - Sources/BestOCRKit/CoreTypes.swift
  - Sources/BestOCRKit/Triage/TriageDivergence.swift
  - evidence/schema.md
  - Tests/BestOCRKitTests/TriageProbeTests.swift
  - docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md
  - plugins/bestocr/skills/ocr/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-ask/SKILL.md
  - Sources/BestOCRKit/Triage/TriageRunner.swift
  - Tests/BestOCRKitTests/TriageRunTests.swift
  - .agents/skills/spectra-drift/SKILL.md
  - README.md
  - Sources/BestOCRKit/Triage/TriageProbe.swift
  - .spectra.yaml
  - Tests/BestOCRKitTests/TriageDivergenceTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .claude-plugin/marketplace.json
  - Sources/BestOCRKit/Triage/TriageReport.swift
  - Sources/bestocr/BestOCRMain.swift
  - .agents/skills/spectra-propose/SKILL.md
  - Sources/BestOCRMCPCore/Server.swift
  - Sources/bestocr/TriageCommand.swift
-->

---
### Requirement: Divergence measurement between extraction methods

When divergence measurement is requested, the triage capability SHALL, for suspect pages only, extract text via both `pdftotext` and the Vision engine, align the two extractions using the existing item extraction and alignment machinery, and report a per-page divergence score in [0, 1]. The consensus estimator implementations SHALL NOT be modified; informants are extraction methods, not OCR engines. The `divergence` report field SHALL be absent (not empty) when divergence measurement did not run.

#### Scenario: Divergence on demand only

- **WHEN** triage is invoked without the divergence option
- **THEN** the report contains no `divergence` field and no Vision extraction is performed

#### Scenario: Divergence reported, route unchanged

- **WHEN** divergence measurement runs on a suspect page
- **THEN** the per-page score appears in the report and the page's route remains `render_suspect_pages`


<!-- @trace
source: triage-single-entry
updated: 2026-08-03
code:
  - Tests/BestOCRKitTests/TriageReportTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - Tests/BestOCRMCPCoreTests/ServerTests.swift
  - plugins/bestocr/.claude-plugin/plugin.json
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-debug/SKILL.md
  - changelog/20260803_p14-triage-single-entry.md
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - Sources/BestOCRKit/CoreTypes.swift
  - Sources/BestOCRKit/Triage/TriageDivergence.swift
  - evidence/schema.md
  - Tests/BestOCRKitTests/TriageProbeTests.swift
  - docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md
  - plugins/bestocr/skills/ocr/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-ask/SKILL.md
  - Sources/BestOCRKit/Triage/TriageRunner.swift
  - Tests/BestOCRKitTests/TriageRunTests.swift
  - .agents/skills/spectra-drift/SKILL.md
  - README.md
  - Sources/BestOCRKit/Triage/TriageProbe.swift
  - .spectra.yaml
  - Tests/BestOCRKitTests/TriageDivergenceTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .claude-plugin/marketplace.json
  - Sources/BestOCRKit/Triage/TriageReport.swift
  - Sources/bestocr/BestOCRMain.swift
  - .agents/skills/spectra-propose/SKILL.md
  - Sources/BestOCRMCPCore/Server.swift
  - Sources/bestocr/TriageCommand.swift
-->

---
### Requirement: Explicit degradation without poppler

When `pdftotext` is unavailable, the triage capability SHALL return a report whose `degraded` field carries a reason and an executable install hint, with route `ocr_full` (behaviour identical to the pre-triage pipeline). Triage SHALL NOT silently pretend measurement occurred.

#### Scenario: poppler missing

- **WHEN** `pdftotext` cannot be located
- **THEN** the report has `degraded.reason` naming the missing tool, `degraded.install_hint` = "brew install poppler", route `ocr_full`, and an empty `pages` array


<!-- @trace
source: triage-single-entry
updated: 2026-08-03
code:
  - Tests/BestOCRKitTests/TriageReportTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - Tests/BestOCRMCPCoreTests/ServerTests.swift
  - plugins/bestocr/.claude-plugin/plugin.json
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-debug/SKILL.md
  - changelog/20260803_p14-triage-single-entry.md
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - Sources/BestOCRKit/CoreTypes.swift
  - Sources/BestOCRKit/Triage/TriageDivergence.swift
  - evidence/schema.md
  - Tests/BestOCRKitTests/TriageProbeTests.swift
  - docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md
  - plugins/bestocr/skills/ocr/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-ask/SKILL.md
  - Sources/BestOCRKit/Triage/TriageRunner.swift
  - Tests/BestOCRKitTests/TriageRunTests.swift
  - .agents/skills/spectra-drift/SKILL.md
  - README.md
  - Sources/BestOCRKit/Triage/TriageProbe.swift
  - .spectra.yaml
  - Tests/BestOCRKitTests/TriageDivergenceTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .claude-plugin/marketplace.json
  - Sources/BestOCRKit/Triage/TriageReport.swift
  - Sources/bestocr/BestOCRMain.swift
  - .agents/skills/spectra-propose/SKILL.md
  - Sources/BestOCRMCPCore/Server.swift
  - Sources/bestocr/TriageCommand.swift
-->

---
### Requirement: Triage surfaces

The triage capability SHALL be exposed as a CLI subcommand (human-readable summary by default, full report with `--json`) and as an MCP tool returning the report as JSON. Both surfaces SHALL report the effective thresholds (after environment overrides) in the `thresholds` field.

#### Scenario: MCP parity

- **WHEN** the MCP `triage` tool is invoked with an `input_path`
- **THEN** it returns the same `TriageReport` JSON the CLI produces with `--json` for the same input


<!-- @trace
source: triage-single-entry
updated: 2026-08-03
code:
  - Tests/BestOCRKitTests/TriageReportTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - Tests/BestOCRMCPCoreTests/ServerTests.swift
  - plugins/bestocr/.claude-plugin/plugin.json
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-debug/SKILL.md
  - changelog/20260803_p14-triage-single-entry.md
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - Sources/BestOCRKit/CoreTypes.swift
  - Sources/BestOCRKit/Triage/TriageDivergence.swift
  - evidence/schema.md
  - Tests/BestOCRKitTests/TriageProbeTests.swift
  - docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md
  - plugins/bestocr/skills/ocr/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-ask/SKILL.md
  - Sources/BestOCRKit/Triage/TriageRunner.swift
  - Tests/BestOCRKitTests/TriageRunTests.swift
  - .agents/skills/spectra-drift/SKILL.md
  - README.md
  - Sources/BestOCRKit/Triage/TriageProbe.swift
  - .spectra.yaml
  - Tests/BestOCRKitTests/TriageDivergenceTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .claude-plugin/marketplace.json
  - Sources/BestOCRKit/Triage/TriageReport.swift
  - Sources/bestocr/BestOCRMain.swift
  - .agents/skills/spectra-propose/SKILL.md
  - Sources/BestOCRMCPCore/Server.swift
  - Sources/bestocr/TriageCommand.swift
-->

---
### Requirement: Triage estimand registered, unmeasured

The evidence schema SHALL define a versioned estimand for triage route accuracy (agreement between the recommended route and a human-annotated correct route), and SHALL mark it evidence-pending until an annotated reference set exists. Threshold defaults SHALL be documented as uncalibrated single-sample inductions. No ranking or accuracy number SHALL be published without measured rows.

#### Scenario: No fake precision

- **WHEN** the estimand section is added to the evidence schema
- **THEN** it contains the formula and the evidence-pending marker, and no numeric accuracy claim

<!-- @trace
source: triage-single-entry
updated: 2026-08-03
code:
  - Tests/BestOCRKitTests/TriageReportTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - Tests/BestOCRMCPCoreTests/ServerTests.swift
  - plugins/bestocr/.claude-plugin/plugin.json
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-debug/SKILL.md
  - changelog/20260803_p14-triage-single-entry.md
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - Sources/BestOCRKit/CoreTypes.swift
  - Sources/BestOCRKit/Triage/TriageDivergence.swift
  - evidence/schema.md
  - Tests/BestOCRKitTests/TriageProbeTests.swift
  - docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md
  - plugins/bestocr/skills/ocr/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-ask/SKILL.md
  - Sources/BestOCRKit/Triage/TriageRunner.swift
  - Tests/BestOCRKitTests/TriageRunTests.swift
  - .agents/skills/spectra-drift/SKILL.md
  - README.md
  - Sources/BestOCRKit/Triage/TriageProbe.swift
  - .spectra.yaml
  - Tests/BestOCRKitTests/TriageDivergenceTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .claude-plugin/marketplace.json
  - Sources/BestOCRKit/Triage/TriageReport.swift
  - Sources/bestocr/BestOCRMain.swift
  - .agents/skills/spectra-propose/SKILL.md
  - Sources/BestOCRMCPCore/Server.swift
  - Sources/bestocr/TriageCommand.swift
-->