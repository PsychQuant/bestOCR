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
- estimator 是 EM 式加權多數決（"-lite"）：無混淆矩陣，**無法做方向性混淆辨別**
  （分不出「申→甲」與「甲→申」哪個方向更常錯）。
- 資源上限：每頁最多 2000 個 item、單行最長 4000 字元，超限截斷（防退化輸出
  造成 CPU/OOM）；只跑本機引擎，顯式指定 cloud／需網路引擎會被拒絕。
- 表格支援限 pipe 語法（`| a | b |`）：escaped pipe（`\|`）與無首尾 `|` 的表格
  不支援；math 偵測限 `$`/`$$`/`\(`/`\[`/常見數學 environment——bare LaTeX 指令
  與 Unicode 方程不會被分類為 math（仍以一般行參與共識）。
- 報告 JSON `schema_version: 2` 起 `responses`／consensus 文字為各引擎**原始
  rendering**（v1 為 normalized 文字）；空 table cell 是位置佔位，不參與投票，
  **全空的 aligned slot 會整個省略**（`item_count` 是「至少一個真實回應的
  verdict 數」，item index 因此可能不連續）；只出過佔位符的引擎不會出現在
  competence／agreement。
- Solo item 只在**完全相同的 gap 區間**內跨引擎合併（保守政策：錯拆送人工
  複核是安全的，錯併製造假 corroboration 是危險的）——引擎各漏不同中段行時，
  相同內容可能拆成兩個低共識 item。
- 報告的 `converged` 為 false 時表示迭代達上限、估計未達定點；competence 仍是對
  已發布 verdict 的一致率（內部一致），而在發布 competence 下不再是贏家的
  verdict 會被強制標為低共識送人工複核。
