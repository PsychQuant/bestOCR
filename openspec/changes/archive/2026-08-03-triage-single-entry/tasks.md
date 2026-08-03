## 1. Triage 核心（BestOCRKit）

- [x] 1.1 建立 `TriageReport` Codable model（Sources/BestOCRKit/Triage/TriageReport.swift）：欄位逐字對齊 design 的 Implementation Contract（pages / suspect_pages / divergence（nil = 未跑，絕不出空物件）/ route 四值 / per_page_routes / thresholds / degraded）。驗證：round-trip encode/decode 單元測試通過，divergence 為 nil 時 JSON 不含該 key。
- [x] 1.2 實作 Task 1 per-page 文字層探測（Sources/BestOCRKit/Triage/TriageProbe.swift）：對 PDF 逐頁跑 `pdftotext -f N -l N`、去空白計字元數，與 `BESTOCR_TRIAGE_TEXT_MIN`（預設 200）比較得 `has_text_layer`；圖片輸入直接判無文字層不呼叫 probe。驗證：TriageProbeTests 以 born-digital 與 scanned 兩類 fixture 斷言 per-page 判定與 `text_direct` / `ocr_full` route。（covers: Per-page text-layer probe）
- [x] 1.3 實作 Task 2 結構掃描與 route 聚合（同 TriageProbe.swift）：對 text-bearing 頁計算 fragment ratio（>3 token 的行中 1–2 字元 token 佔比），超過 `BESTOCR_TRIAGE_FRAG_MAX`（預設 0.6）標 suspect；聚合出 `mixed` route 時 `per_page_routes` 必填且 text-bearing 頁絕不路由到 OCR。驗證：公式頁 fixture 進 `suspect_pages`、散文頁不進；三頁 hybrid fixture 斷言 spec 的 Example 逐字段成立。（covers: Structure scan for suspect pages）
- [x] 1.4 實作 poppler 缺席顯式降級：pdftotext 定位失敗時回 `degraded`（reason + "brew install poppler" hint）、route `ocr_full`、pages 空陣列；工具定位採注入式（參考 PipelineFlow.locateConverter），測試不得 `setenv`。驗證：注入假定位器的降級測試斷言 degraded 欄位與行為等同現行流程。（covers: Explicit degradation without poppler）
- [x] 1.5 實作 Task 3 divergence 薄 entry（Sources/BestOCRKit/Triage/TriageDivergence.swift）：僅對 suspect pages 以 `pdftotext` 與 Vision 兩個抽取方法取文字，餵 `ItemExtractor` + 既有 alignment 得 [0,1] 分歧分數；不修改 ConsensusPipeline / estimator 任何檔案。驗證：TriageDivergenceTests 斷言公式頁分歧 > 散文頁分歧，且未帶 divergence 選項時不執行 Vision（以呼叫計數 spy 斷言）。（covers: Divergence measurement between extraction methods）

## 2. Surfaces（CLI + MCP）

- [x] 2.1 [P] 新增 CLI 子指令 `bestocr triage <input> [--pages RANGE] [--divergence] [--json]`（Sources/bestocr/TriageCommand.swift）：預設人讀摘要（route + 各頁測量值 + degraded 轉述），`--json` 輸出完整 TriageReport。驗證：`swift run bestocr triage` 對 fixture 的兩種輸出人工走查 + 整合測試斷言 `--json` 可 decode 回 TriageReport。（covers: Triage surfaces）
- [x] 2.2 [P] 註冊 MCP `triage` tool（Sources/BestOCRMCPCore/Server.swift）：schema `{ input_path, pages?, divergence? }`，回傳與 CLI `--json` 相同的 TriageReport；thresholds 欄位含 env 覆寫後生效值。驗證：MCP smoke — tools/list 含 triage、同一 fixture 之 MCP 回傳與 CLI `--json` 逐字段相等。（covers: Triage surfaces）

## 3. Evidence 與文件

- [x] 3.1 [P] `evidence/schema.md` 新增 triage estimand 段：`triage.route_accuracy@v1` 公式（建議 route 對人工標註正解的命中率）、evidence-pending 標記、閾值預設值標註「單樣本歸納、未校準」。驗證：內容審查 — 段落有公式、無任何數字準確率宣稱；estimand 命名符合 schema §3 慣例。（covers: Triage estimand registered, unmeasured）
- [x] 3.2 [P] 重寫 `plugins/bestocr/skills/ocr/SKILL.md` 為單一入口：先呼叫 MCP `triage`，依 route 展開 TaskCreate flowchart（A 文字直出 / B 只 render suspect 頁交 agent 直讀 / C 既有 auto-routing 鏈 + 品質不足升級 consensus），路徑決策必轉述測量值，degraded 必轉述 install hint，收尾維持 evidence-ingest 建議；`consensus` / `ocr-to` / `compare` / `evidence-ingest` skill 檔案零改動。驗證：SKILL.md 對照 ocr-single-entry spec 逐 Requirement 走查，另以 `git status` 確認下游 skill 檔未被觸碰。（covers: Single standard entry point, Trackable flowchart execution, Degraded-mode transparency, Downstream skills preserved）
- [x] 3.3 [P] 文件同步：`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md` §12 的 text-layer-aware deferred item 加一行狀態註記（revisited by openspec change triage-single-entry）；`CLAUDE.md` 架構速覽與里程碑加 Triage module 條目。驗證：內容審查 — 歷史 spec 僅追加註記一行、無其他改動。

## 4. 收尾

- [x] 4.1 全量測試綠 + 版號與 changelog：`swift test`（pipefail）全綠含新測試；`plugins/bestocr/.claude-plugin/plugin.json` 版號 bump；新增 changelog 條目（changelog/ 目錄，命名循 p-milestone 慣例）記錄本 change 摘要與 #35 引用。驗證：`set -o pipefail; swift test | tail` exit 0；changelog 檔存在且引用 #35 與 bestOCR-bench#1。
