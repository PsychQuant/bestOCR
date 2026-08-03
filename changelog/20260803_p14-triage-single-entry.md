# P14 — triage 單一入口（測量式分診）

- **日期**: 2026-08-03
- **Issue**: #35（openspec change `triage-single-entry`；sister: PsychQuant/bestOCR-bench#1 estimand gate 同步，blocked by 本批）
- **版本**: kit/plugin/marketplace 三號統一 0.9.0 → 0.10.0

## 摘要

在「選引擎」（recommend/auto-routing）之上補「選路徑」層：per-page 測量式分診，
回答更上游的問題——**這個檔案需不需要 OCR？** 動機是 #35 實測：8/9 精算類 PDF
為原生文字層（OCR 主動引入辨識誤差），公式頁 `pdftotext` 靜默丟運算符
（silent corruption，先前無防線）。

## 內容

- `Sources/BestOCRKit/Triage/`（新 module）：
  - `TriageReport` — 分診報告 Codable 契約（snake_case 逐欄位；divergence
    nil = 未跑、[:]  = 跑了無可報，P12 紀律）
  - `TriageProbe` — Task 1 per-page 文字層探測 + Task 2 碎片密度結構掃描；
    route 聚合（`text_direct` / `render_suspect_pages` / `ocr_full` / `mixed`，
    per-page verdict 為準——hybrid 混頁文件是這個設計防的失效類）；poppler
    缺席顯式降級（degraded + install hint，行為退回現行流程）
  - `TriageDivergence` — Task 3 抽取方法 informant 對（pdftotext vs Vision）
    分歧測量，只復用 `ItemExtractor` + `ConsensusAlignment`（estimator /
    ConsensusPipeline 零改動）；只跑 suspect pages（cheap triage 成本契約）
  - `TriageRunner` — async production wiring（render suspect 頁 → Vision）；
    divergence 失敗 loud fail（一邊全空會偽裝成最大分歧誤導 caller）
- Surfaces（四件套 parity）：CLI `bestocr triage <input> [--pages] [--divergence]
  [--json]` + MCP `triage` tool（同一 TriageReport JSON）
- `bestocr:ocr` skill 重寫為**單一標準入口**：triage 先行，TaskCreate flowchart
  三路徑分流；下游 skills（consensus / ocr-to / compare / evidence-ingest）
  契約不動
- `evidence/schema.md`：`triage.route_accuracy@v1` estimand（defined-unmeasured；
  referent = 人工標註正解路徑）；閾值預設（200 字元/頁、0.6 碎片比）標
  uncalibrated single-sample，env 可覆寫（`BESTOCR_TRIAGE_TEXT_MIN` /
  `BESTOCR_TRIAGE_FRAG_MAX`）
- 2026-07-21 spec §12 deferred item（text-layer shortcut）標記 revisited；
  §5.2 born-digital 重 OCR accepted cost 對 text-bearing 頁被推翻

## 驗證

- `swift test --no-parallel`：328 tests / 49 suites 全綠（新增 24 tests / 3
  suites：TriageReportTests / TriageProbeTests / TriageDivergenceTests，含
  spec Example 逐字段釘住與 poppler 缺席注入測試）
- 真檔 smoke：born-digital PDF → `route: text_direct`（2640 字元、
  fragment_ratio 0.02）、JSON 契約 snake_case 逐欄位吻合、nil 欄位 key 缺席
