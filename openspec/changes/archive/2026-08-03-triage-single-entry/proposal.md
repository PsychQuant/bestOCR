## Why

現行 `bestocr:ocr` 流程的起點是「要 OCR 這個檔案」，缺少更上游的「這個檔案需不需要 OCR」判斷。實測（#35）：9 份 PDF 中 8 份為原生文字層 — 對它們跑 OCR 是主動引入辨識誤差；而含數學公式的頁面 `pdftotext` 會靜默丟失全部運算符號（silent corruption，最危險的失效模式），純文字 OCR 也接不住。目前無任何防線。

## What Changes

- BestOCRKit 新增 **Triage module**：per-page 文字層探測（Task 1）、碎片密度結構掃描（Task 2）、抽取方法間 divergence 計算（Task 3，復用 ItemExtractor + estimator，informant 從「OCR 引擎」泛化為「抽取方法」）
- 新增 MCP `triage` tool 與 CLI `bestocr triage` 子指令（四件套 parity；輸出 = 分診報告：路徑建議 A/B/C + 命中頁碼，執行由 caller 決定）
- `bestocr:ocr` skill 重寫為**單一標準入口**：TaskCreate flowchart 調度（Flow A），依 triage 報告走三條路徑之一 — A `pdftotext` 直出 / B render 命中頁交 agent 多模態直讀 / C 掃描件走既有 recommend → run → consensus
- 判準閾值（文字層字元數、碎片密度）config 化、預設值標 evidence-pending，不寫死
- triage estimand（判準命中率）定義進 `evidence/schema.md`（有公式、無數字 — P8 先例）
- 修訂 2026-07-21 design spec §5.2「born-digital re-OCR cost accepted」決策：text-layer-aware shortcut 正式化（§12 deferred item 的 revisit）

## Capabilities

### New Capabilities

- `triage`: 測量式分診 — per-page 文字層/結構/分歧度測量，輸出三路徑建議與命中頁碼；poppler 缺席時顯式降級
- `ocr-single-entry`: `bestocr:ocr` skill 成為單一入口，以 task 化 flowchart 調度 triage 報告對應的執行路徑

### Modified Capabilities

(none)

## Impact

- Affected specs: `triage`（新）、`ocr-single-entry`（新）
- Affected code:
  - New: Sources/BestOCRKit/Triage/TriageProbe.swift, Sources/BestOCRKit/Triage/TriageDivergence.swift, Sources/BestOCRKit/Triage/TriageReport.swift, Sources/bestocr/TriageCommand.swift, Tests/BestOCRKitTests/TriageProbeTests.swift, Tests/BestOCRKitTests/TriageDivergenceTests.swift
  - Modified: Sources/BestOCRMCPCore/Server.swift, plugins/bestocr/skills/ocr/SKILL.md, evidence/schema.md, plugins/bestocr/.claude-plugin/plugin.json, CLAUDE.md, docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md
  - Removed: (none)
