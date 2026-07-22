---
name: ocr
description: 把任意 PDF 或圖片轉成 Markdown——bestOCR 依測量證據自動選引擎(auto routing + fallback chain),或使用者指定引擎。當使用者說「幫我 OCR 這個」「這個 PDF 轉文字/Markdown」「掃描檔辨識」「這張截圖的字抓出來」並附上檔案時使用。VLM 引擎需要 ollama serve 在跑;cloud.* 引擎會把文件送出本機,只在使用者明確要求時用。
---

# ocr — 任意 PDF/圖片 → Markdown

這是**對話式 skill**:使用者用自然語言請你 OCR 某個檔案,你用 MCP 的 `ocr` tool(優先,模型保溫)或 `bestocr` CLI 完成。

## 流程

1. **確認輸入**:絕對路徑的 PDF 或圖片(png/jpg/jpeg/tiff/heic/bmp)。沒給就問。
2. **判斷 doc-type**(進 condition tuple,將來可 ingest 成證據):
   - 數學/學術 PDF → `math_pdf`(並考慮 `math: true`)
   - 掃描書/檔案 → `scanned_book`;截圖 → `screenshot`;其他 → 問或 `unspecified`
3. **呼叫**(擇一):
   - MCP tool `ocr`:`{input_path, doc_type, priority?, math?, lang?}` — 不給 `engine` 就是 auto routing。多頁長文件加 `async: true`,再用 `ocr_status`/`ocr_result` 輪詢。
   - CLI:`bestocr run <input> --doc-type <type> [--priority quality|speed] [--math] [--lang zh-Hant,en] [--out DIR]`
4. **回報**:輸出的 markdown 路徑 + 用了哪個引擎;若有 `↷ ... skipped` fallback 行,一併轉述(路由決策要透明)。
5. **順手建議**:這次 run 若值得成為證據(條件乾淨、文件типичный),提醒可用 `/bestocr:evidence-ingest` 升級成 T2 row。

## 路徑安全

- 優先走 MCP `ocr` tool 的 `input_path` 參數(JSON 傳值,不經 shell 解析)。
- 組 CLI 指令時雙引號只擋空白/中文/括號,**擋不住** `$( )`、反引號、`"`、
  換行等——檔名含這類字元時改用安全傳遞(避免把 raw 檔名內插進 shell
  字串),或先改名再處理。

## 引擎備忘

- `auto`(預設)= recommend 排序 + fallback;明確指定 `--engine` 則不 fallback。
- `vlm.*` 需要 `ollama serve`;`ext.*` 需要對應 Python 套件;`cloud.*` **文件離機**,只在使用者明說時用。
- 引擎狀態隨時可查:MCP `list_engines` 或 `bestocr list-engines`。
