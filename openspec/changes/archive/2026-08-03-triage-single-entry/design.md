## Context

bestOCR 現行流程假設「輸入必走 OCR」：`InputNormalizer` 把 PDF render 成頁面影像、引擎只看影像（2026-07-21 spec §5.2，該 spec 明文接受 born-digital PDF 被重複 OCR 的成本、把 text-layer shortcut 列為 §12 deferred item）。#35 帶實測證據 revisit：8/9 樣本為原生文字層（OCR 引入不必要辨識誤差）、公式頁 `pdftotext` 靜默丟運算符（silent corruption 無防線）。

既有可復用資產：`ItemExtractor.extract(page:text:)` 是 text-in 零引擎耦合；`ConsensusEstimator` + adjudicators 消費 response 矩陣；但 `ConsensusPipeline.execute(inputPath:engineIDs:)` 與 engine spawn 耦合，不能直接把 `pdftotext` 當 informant。

約束：plugin 使用者只有 `bestocr-mcp` binary、沒有 CLI（P10 教訓）；Flow B（human-direct CLI）要求零 agent 依賴（spec §2 dual flows）；`pdftotext` 屬 poppler、非必裝依賴（鐵律 4 probe 紀律）；evidence 紀律要求判準本身可被測量（鐵律 2）。

## Goals / Non-Goals

**Goals:**

- 在「選引擎」之上補「選路徑」層：per-page 測量式分診，輸出三路徑建議（A `pdftotext` 直出 / B render 命中頁交 caller 多模態直讀 / C 走既有 OCR 鏈）
- triage 能力四件套 parity：kit module + MCP tool + CLI 子指令 + skill 調度
- `bestocr:ocr` skill 成為單一入口（Flow A），以 TaskCreate flowchart 展開
- 判準閾值 config 化並納入 evidence 體系（estimand 有公式、無數字）

**Non-Goals:**

- 不改 `ConsensusPipeline` / estimator / adjudicators 實作（只在其下游復用 text 層 API）
- 不改 `recommend` 引擎排序邏輯、不改任何 OCR 引擎
- 路徑 B 的多模態呼叫本身（bestOCR 只負責 render 與頁碼決策，讀圖由 caller 的 agent 完成）
- 閾值校準與標註參照集（bench corpus 工作，另案）；bestOCR-bench estimand gate 同步（bestOCR-bench#1，blocked by 本案）
- 歷史 dated specs（docs/superpowers/specs/）的遷移或改寫 — 僅在 2026-07-21 spec 加一行 §12 狀態註記指向本 change

## Decisions

1. **判準 code 化進 binary，skill 只是調度殼** — Flow B 要零 agent 依賴、plugin 使用者無 CLI（P10）、且散文判準無法被 evidence 體系測量（P9「安全規則變成 code」同 pattern）。替代案「判準寫在 SKILL.md 的 bash」被否決：三個 surface 會 drift、CLI 使用者拿不到。
2. **獨立 `triage` tool，不擴 `pipeline` 參數** — triage 的本質是「回報告，執行由 caller 決定」；路徑 B 的執行（agent 讀圖）根本不在 pipeline 可執行範圍內。塞進 pipeline 會把測量與執行耦死、參數空間膨脹。
3. **per-page 判定，file-level verdict 只是聚合** — file-level Task 1 接不住 hybrid 混頁文件（首頁原生 + 後頁掃描 → 掃描頁靜默漏抽，正是本案要消滅的 silent corruption 類型）。route 詞彙含 `mixed`：per-page routes 各自成立。
4. **Task 3 divergence 的 informant 對 = `pdftotext` vs `vision`（Apple Vision）** — Vision 是零依賴、in-process、最快的本機引擎；只對 suspect pages 跑。經新薄 entry（TriageDivergence）餵兩份文字進 ItemExtractor + alignment，不動 ConsensusPipeline。替代案（VLM 當 informant）被否決：cheap triage 的成本預算是毫秒級。
5. **閾值走 env 覆寫 + 內建預設**（`BESTOCR_TRIAGE_TEXT_MIN` 預設 200 字元/頁、`BESTOCR_TRIAGE_FRAG_MAX` 預設 0.6）— 對齊 repo 既有 env 慣例（`BESTOCR_PYTHON` 等）；預設值在 schema.md 標 evidence-pending（單樣本歸納，待校準）。
6. **poppler 缺席 = 顯式降級** — `TriageReport.degraded` 欄位帶 reason + installHint，route 建議退回 `ocr_full`（等同現行為）並在所有 surface 轉述；絕不靜默假裝有分診。
7. **既有 skills 保留** — `consensus` / `ocr-to` / `compare` / `evidence-ingest` 不刪不改名（published surface），成為入口 flowchart 的下游節點；只重寫 `ocr` SKILL.md。

## Implementation Contract

**Behavior**：使用者對任意 PDF/圖片呼叫 `triage`（MCP tool / CLI）獲得分診報告；`/bestocr:ocr` skill 先跑 triage 再依報告展開對應路徑。原生文字層文件不再進 OCR；公式/表格 suspect 頁獲得「render 後交 agent 直讀」出口；掃描件走既有鏈不變。poppler 缺席時報告帶 `degraded` 且行為等同現行流程。

**Interface / data shape**：

- CLI：`bestocr triage <input> [--pages RANGE] [--divergence] [--json]`（人讀摘要；`--json` 出完整報告）
- MCP tool：`triage { input_path: string, pages?: string, divergence?: bool }` → TriageReport JSON
- `TriageReport`（Codable，逐字段）：
  - `pages: [{ page: Int, text_chars: Int, has_text_layer: Bool, fragment_ratio: Double, suspect: Bool }]`
  - `suspect_pages: [Int]`
  - `divergence: { informants: [String], per_page: { "N": Double } }?`（nil = 未跑 Task 3；空物件不出現 — 對齊 P12「nil = 無此概念」紀律）
  - `route: "text_direct" | "render_suspect_pages" | "ocr_full" | "mixed"`
  - `per_page_routes: { "N": String }`（route == mixed 時必填）
  - `thresholds: { text_chars_min: Int, fragment_ratio_max: Double }`（實際生效值，含 env 覆寫後）
  - `degraded: { reason: String, install_hint: String }?`
- 閾值 env：`BESTOCR_TRIAGE_TEXT_MIN`、`BESTOCR_TRIAGE_FRAG_MAX`
- estimand（schema.md 新段）：`triage.route_accuracy@v1` — 判準建議路徑相對人工標註正解的命中率；有公式、無數字，標 evidence-pending

**Verification**：`swift test` 新增 TriageProbeTests（四類 fixture：原生/掃描/公式/hybrid + poppler 缺席降級，缺席用注入模擬非 setenv）與 TriageDivergenceTests（公式頁 divergence > 散文頁）；MCP tool 經 `bestocr-mcp` smoke（tools/list 含 triage）；skill 層以 SKILL.md 契約人工走查。

**Scope boundary**：in scope = kit Triage module、MCP/CLI surface、ocr SKILL.md 重寫、schema.md estimand 段、plugin bump；out of scope = 引擎/estimator/recommend 內部、多模態呼叫、閾值校準、bench 同步。
