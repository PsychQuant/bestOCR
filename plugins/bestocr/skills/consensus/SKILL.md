---
name: consensus
description: 多引擎共識 OCR——同一份文件逐一跑多個本機引擎,對齊後用 CCT/Dawid-Skene 式估計裁決分歧,輸出共識轉錄＋各引擎分類型 competence＋低共識複核清單。當使用者說「多個模型一起辨識」「OCR 結果互相驗證」「哪個引擎在這類內容比較準」「只想人工複核有分歧的地方」時使用。純本機,文件不離機。
---

# consensus — 多引擎共識 OCR（CCT/Dawid-Skene-lite）

模型＝informants、辨識單元＝items（散文以行、表格逐 cell）、輸出＝response 矩陣。
迭代估計：competence 加權多數決 ⇄ 各引擎 per-type competence（Laplace 平滑），
不需要 ground truth。低共識 item（頂端平票或勝出回應支持者 <2）標 ⚠ 供人工複核
——把「全文校對」縮成「只看分歧處」。

## 流程

1. 確認輸入檔與引擎集合。預設用全部可用本機引擎（`bestocr list-engines` 可查）；
   **至少要 2 個**，CCT 建議 ≥3 才穩。
2. 跑：`bestocr consensus <input> [--engines vision,vlm.paddleocr-vl,vlm.glm-ocr,vlm.ovisocr2] [--doc-type ...] [--pages 1-3] [--dpi 150] [--out DIR]`
   - MCP 對應：`consensus` tool（長文件帶 `async=true`，用 `ocr_status`／`ocr_result` 輪詢）。
3. 回報：參與引擎、item 數與低共識數、各引擎 overall competence 排序、
   兩個輸出路徑（`<stem>.consensus.md` 轉錄、`<stem>.consensus.json` 報告）。
4. 建議使用者只複核 `low_consensus` 清單（報告 JSON 內含每個分歧 item 的
   各引擎原始回應），不必通讀全文。

## 誠實邊界（必轉述）

- **共識 ≠ 真值**：全體引擎同錯（同一難字大家都錯）時共識也錯。報告的
  `agreement` 矩陣是引擎間錯誤相關的診斷（相關性高會虛增 competence），
  MVP 只揭露不修正。
- **表格結構不重建**：轉錄檔中表格降為逐 cell 行；表格請以報告 JSON 對照原檔。
- competence 是「與共識一致率」（Laplace 平滑），不是對 ground truth 的正確率；
  無人 corroborate 的 solo item 與平票 item 不計入 competence。
- 引擎**逐一**執行（本機 VLM 共享 GPU／模型伺服器，循序是刻意設計，非平行）。
- 報告的 `converged` 為 false 時表示迭代達上限、估計未達定點（結果仍內部一致）。
