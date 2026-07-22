---
name: ocr-to
description: 把 PDF/圖片 OCR 後轉成使用者指定的目標檔案格式(v1 支援 docx)——bestOCR auto-routing 出 Markdown,再經 macdoc CLI 轉檔。當使用者說「把這個 PDF 轉成 Word」「掃描檔轉 docx」「考古題轉成可編輯的檔案」「OCR 完給我 Word 檔」時使用。需要 macdoc CLI;數學公式在 v1 以 LaTeX 原文呈現(無 OMath 原生渲染)。
---

# ocr-to — 任意 PDF/圖片 → 目標格式檔案(v1: docx)

這是**對話式 skill**:OCR(`/bestocr:ocr` 同款 auto-routing)+ 轉檔(macdoc CLI)的
串接。skill 只做 orchestration——兩個 CLI 各管各的,這裡不重新實作任何引擎或轉檔邏輯。

## 流程

1. **Probe(先於一切)**:
   - **轉檔端(必要)**:`command -v macdoc`。缺席 → **停下**,給安裝提示:
     ```
     claude plugin marketplace add PsychQuant/macdoc
     claude plugin install macdoc@macdoc
     ```
     (或從 https://github.com/PsychQuant/macdoc 取得 CLI)。不可假裝成功。
   - **OCR 端**:MCP `ocr` tool 優先(plugin 內建,模型保溫);沒有 MCP 時
     fallback `command -v bestocr` CLI。兩者皆缺才算 OCR 端不可用。
2. **確認輸入與目標格式**:
   - 輸入:絕對路徑的 PDF 或圖片,單檔或多檔(資料夾 → 列舉後與使用者確認清單)。
   - 目標格式:v1 只支援 `docx`。使用者沒指定 → 確認「輸出 docx 對嗎?」;
     要求其他格式 → 說明 v1 限制(docx-only,PsychQuant/bestOCR#1 拍板)。
3. **逐檔執行**(檔名含中文/括號,路徑一律加引號):
   - OCR:MCP tool `ocr` `{input_path, doc_type, math?, out?}`(多頁長文件
     `async: true` + `ocr_status`/`ocr_result` 輪詢),或 CLI:
     ```bash
     bestocr run "<input>" --doc-type <type> --out "<workdir>"   # → <stem>.md
     ```
   - 轉檔:
     ```bash
     macdoc convert --to docx "<workdir>/<stem>.md"              # → <stem>.docx
     ```
   doc-type 判斷同 `/bestocr:ocr`(掃描考卷/文件 → `scanned_book` 或
   `scanned_exam`;數學密集加 `--math`)。多頁長文件先跟使用者確認頁數範圍。
4. **輸出檢查**(每檔):
   - docx 存在且非空;有數學內容時抽查公式——`$...$` LaTeX 應**原樣字面保留**。
   - 發現公式被吃掉/亂碼 → 屬 macdoc 轉檔問題,提議開 issue 到 PsychQuant/macdoc。
5. **回報**:每檔的輸出路徑 + 使用引擎(fallback 行照轉述)+ **已知限制聲明**:
   > 數學公式在 docx 內以 LaTeX 原文呈現(如 `$y = \beta_0 + \beta_1 x$`),
   > 非 Word 原生公式。OMath 升級追蹤於 PsychQuant/bestOCR#3。

## 邊界

- **v1 docx-only**;pdf/pptx/html 等其他 macdoc 支援格式尚未納入(擴充另議)。
- OCR 品質由 bestOCR 引擎與 evidence routing 決定;轉檔忠實度由 macdoc 決定——
  問題要分開歸屬,不要混報。
- cloud.* 引擎文件會離機,只在使用者明說時用(同 `/bestocr:ocr`)。
