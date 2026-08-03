---
name: ocr
description: 任意 PDF/圖片 → 文字輸出的單一標準入口——先測量式分診(triage)再決定路徑:原生文字層直出(零 OCR 零誤差)、公式/表格頁 render 後多模態直讀、掃描件走證據導向 OCR 鏈(auto routing + fallback,可升級多引擎共識)。當使用者說「幫我 OCR 這個」「這個 PDF 轉文字/Markdown」「掃描檔辨識」「這張截圖的字抓出來」並附上檔案時使用。不必先判斷檔案類型——分診就是本 skill 的第一步。VLM 引擎需要 ollama serve 在跑;cloud.* 引擎會把文件送出本機,只在使用者明確要求時用。
---

# ocr — 單一入口:triage 先行,三路徑分流

這是**對話式 skill**,也是 bestOCR 的**單一標準入口**:使用者要把 PDF/圖片變成文字,一律從這裡進。你先跑 MCP `triage` tool 拿分診報告,再依 route 展開對應路徑——**不要**要求使用者自行選擇 `ocr` / `consensus` / `ocr-to`。

## 流程(TaskCreate flowchart)

用 TaskCreate 把實際走到的節點展開成可追蹤 tasks(triage → 路徑執行 → 輸出 → evidence 建議),每個分支決策**必須轉述驅動它的測量值**(字元數、碎片密度、divergence 分數)——路由要透明。

### Task 1 — triage(必走)

1. **確認輸入**:絕對路徑的 PDF 或圖片(png/jpg/jpeg/tiff/heic/bmp)。沒給就問。
2. 呼叫 MCP `triage` tool:`{input_path, pages?, divergence?}`。首輪不帶 `divergence`;報告有 suspect_pages 且想確認公式頁時再帶 `divergence: true` 重跑(只對疑似頁多花兩次抽取)。
3. **degraded 必轉述**:報告帶 `degraded` 時,向使用者說明「路徑分診未執行:{reason}」+ 安裝提示(如 `brew install poppler`),然後照路徑 C(既有 OCR 鏈)繼續——行為等同分診功能出現前,絕不假裝有分診。

### Task 2 — 依 route 分流

| route | 路徑 | 執行 |
|---|---|---|
| `text_direct` | A:文字層直出 | 對整份檔 bash `pdftotext -layout "$input" "$out"`,回報「OCR 已跳過:N 頁原生文字層(首頁 {text_chars} 字元 ≥ 閾值 {text_chars_min})」 |
| `render_suspect_pages` | B:render + 多模態直讀 | 只對 suspect_pages bash `pdftoppm -f N -l N -r 200 -png` render,用 Read tool 讀圖直接轉錄(公式用 LaTeX 表達);非 suspect 頁照路徑 A |
| `ocr_full` | C:既有 OCR 鏈 | MCP `ocr` tool `{input_path, doc_type, priority?, math?, lang?}`(auto routing + fallback;多頁長文件加 `async: true` 輪詢);品質不足或高風險文件 → 升級 MCP `consensus` tool(多引擎共識 + 低共識複核清單) |
| `mixed` | 逐頁分流 | 按 `per_page_routes` 對每頁走上面對應路徑,最後按頁序組回單一輸出 |

路徑 B 的多模態讀圖由**你(agent)**完成——bestOCR 只負責測量與 render 決策;divergence 分數高的頁優先人工複核。

### Task 3 — 輸出與收尾

4. **組裝輸出**:單一 Markdown(mixed 時按頁序合併),回報輸出路徑 + 每頁走了哪條路徑與理由。
5. **順手建議**:這次 run 若值得成為證據(條件乾淨、文件典型),提醒可用 `/bestocr:evidence-ingest` 升級成 T2 row——triage 判準本身也在 evidence 體系內(`triage.route_accuracy@v1`,目前 defined-unmeasured)。

## 路徑安全

- 優先走 MCP tool 的 `input_path` 參數(JSON 傳值,不經 shell 解析)。
- 組 bash 指令(pdftotext / pdftoppm)時,危險在**把 raw 檔名直接內插進會被 shell 解析的 command 字串**——內插的 `$( )`/反引號/`"` 會被執行或破壞語法;安全作法是經變數傳遞(`"$input"` 的展開不會再觸發 command substitution)。
- 檔名以 `-` 開頭時用絕對路徑;無法安全傳遞就先改名。

## 引擎與下游備忘

- 路徑 C 的 `auto`(預設)= recommend 排序 + fallback;明確指定 `engine` 則不 fallback。引擎狀態:MCP `list_engines`。
- `vlm.*` 需要 `ollama serve`;`ext.*` 需要對應 Python 套件;`cloud.*` **文件離機**,只在使用者明說時用。
- `/bestocr:consensus`、`/bestocr:ocr-to`、`/bestocr:compare`、`/bestocr:evidence-ingest` 維持原契約可直接使用——本 skill 是調度它們的入口,不取代它們。
- 閾值可用 env 覆寫:`BESTOCR_TRIAGE_TEXT_MIN`(預設 200 字元/頁)、`BESTOCR_TRIAGE_FRAG_MAX`(預設 0.6)——預設值為單樣本歸納,evidence-pending。
