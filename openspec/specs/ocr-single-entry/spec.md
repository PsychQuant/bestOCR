# ocr-single-entry Specification

## Purpose

TBD - created by archiving change 'triage-single-entry'. Update Purpose after archive.

## Requirements

### Requirement: Single standard entry point

The `bestocr:ocr` skill SHALL be the single standard entry point for turning any PDF or image into text output. It SHALL run triage first and dispatch to exactly one of three execution paths per the triage report: (A) direct text extraction for text-bearing pages, (B) rendering suspect pages for multimodal reading by the calling agent, (C) the existing OCR chain (recommend → run, with consensus escalation) for scanned content. The skill SHALL NOT require the user to choose among `ocr` / `consensus` / `ocr-to` for path selection.

#### Scenario: User provides a born-digital PDF

- **WHEN** the user asks to OCR a file and triage reports route `text_direct`
- **THEN** the skill extracts the text layer directly, reports that OCR was skipped and why, and produces Markdown output without invoking any OCR engine

#### Scenario: User provides a scanned PDF

- **WHEN** triage reports route `ocr_full`
- **THEN** the skill proceeds through the existing auto-routing OCR chain unchanged

#### Scenario: Formula pages present

- **WHEN** triage reports suspect pages with route `render_suspect_pages`
- **THEN** the skill renders only those pages to images and reads them multimodally itself (or delegates to its agent context), while non-suspect text pages take path A


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
### Requirement: Trackable flowchart execution

The skill SHALL expand its execution into discrete tracked tasks (one per flowchart node actually taken: triage, per-path execution, output assembly, evidence suggestion) so the user can observe progress and the decision at each branch. Path decisions SHALL be reported with the measured values that drove them (character counts, fragment ratios, divergence scores).

#### Scenario: Transparent routing

- **WHEN** the skill dispatches any path
- **THEN** the user-visible output names the route taken and the triage measurements that justified it


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
### Requirement: Degraded-mode transparency

When the triage report carries a `degraded` field, the skill SHALL relay the degradation reason and install hint to the user and proceed with the existing OCR chain (pre-triage behaviour).

#### Scenario: poppler missing at skill level

- **WHEN** triage returns degraded
- **THEN** the skill states that path selection was skipped, shows the install hint, and continues as the pre-triage flow would


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
### Requirement: Downstream skills preserved

The existing `consensus`, `ocr-to`, `compare`, and `evidence-ingest` skills SHALL remain available under their current names and contracts. The single entry point orchestrates them; it SHALL NOT replace or rename them.

#### Scenario: Direct downstream invocation still works

- **WHEN** a user invokes `/bestocr:consensus` directly
- **THEN** it behaves exactly as before this change

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