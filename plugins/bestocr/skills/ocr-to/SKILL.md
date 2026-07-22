---
name: ocr-to
description: 把 PDF/圖片 OCR 後轉成使用者指定的目標檔案格式(v1 支援 docx)——bestOCR auto-routing 出 Markdown,再經 macdoc CLI 轉檔。當使用者說「把這個 PDF 轉成 Word」「掃描檔轉 docx」「OCR 完給我 Word 檔」時使用。轉檔器依內容選擇:math 內容在 pandoc 可用時輸出 Word 原生 OMath 公式(此時不需 macdoc);其餘走 macdoc CLI,math 以 LaTeX 原文呈現。
---

# ocr-to — 任意 PDF/圖片 → 目標格式檔案(v1: docx)

這是**對話式 skill**:OCR(`/bestocr:ocr` 同款 auto-routing)+ 轉檔(pandoc/macdoc)的
串接。skill 只做 orchestration——兩個 CLI 各管各的,這裡不重新實作任何引擎或轉檔邏輯。

## 流程

1. **確認輸入與目標格式**(先於 probe——不支援的請求不該先被要求裝依賴):
   - 輸入:絕對路徑的 PDF 或圖片,單檔或多檔(資料夾 → 列舉後與使用者確認清單)。
     先驗證每個路徑存在且是支援的檔型。
   - 目標格式:v1 只支援 `docx`。使用者沒指定 → 確認「輸出 docx 對嗎?」;
     要求其他格式 → 說明 v1 限制(docx-only,PsychQuant/bestOCR#1 拍板),停止。
   - 多頁長文件:與使用者確認頁數範圍(MCP `pages` / CLI `--pages`,如 `"1-3"`)。
2. **Probe**(轉檔端依實際會走的路徑判定必要性):
   - **math 內容且 `command -v pandoc` 在** → pandoc 是本批轉檔器,macdoc **非必要**,缺席不擋。
   - **其餘情況**(無 math,或 pandoc 缺席)→ `command -v macdoc` **必要**。缺席 → **停下**,給安裝提示:
     ```
     claude plugin marketplace add PsychQuant/macdoc
     claude plugin install macdoc@macdoc
     ```
     (或從 https://github.com/PsychQuant/macdoc 取得 CLI;安裝後**重新 probe**
     再繼續)。不可假裝成功。
   - math 判定以 **pandoc 可辨識的 math node** 為準(`$...$`/`$$...$$`;
     code block 內的 `$` 與貨幣寫法不算)——不確定時保守當 non-math 走 macdoc。
   - **OCR 端**:MCP `ocr` tool 優先(plugin 內建,模型保溫);MCP tool 未註冊、
     server 啟動/連線失敗、或 schema 呼叫在建立 job 前就失敗 → fallback
     `command -v bestocr` CLI。**已取得 async job id 後**的中斷 → 繼續
     `ocr_status` 輪詢或明確放棄,**不要**改用 CLI 重跑(避免重複 OCR)。
     兩端皆缺才算 OCR 不可用。
3. **決定輸出目錄(workdir)——防覆寫規則**:
   - workdir 必須是**獨立的輸出目錄**(使用者指定,或新建如 `<input 同層>/ocr-to-out/`),
     **絕不**直接用輸入檔所在資料夾——輸入旁常有既有的同名 `.docx`(如手工轉檔),
     直接輸出會覆寫使用者的檔案。
   - 目標檔已存在 → 先問使用者(覆寫/改名/跳過),不默默覆寫。
   - 批次多檔 stem 重複(不同資料夾的同名檔)→ 輸出檔名加來源區別後綴,不互相覆寫。
4. **逐檔執行**:
   - OCR(MCP,注意參數名):`ocr` `{input_path, doc_type, math?, pages?, out_dir: "<workdir>"}`
     (多頁長文件 `async: true` + `ocr_status`/`ocr_result` 輪詢至 terminal state)。
     完成後**確認 `<workdir>/<stem>.md` 真的存在**(工具回報的實際路徑為準)再進下一步。
   - 或 CLI:
     ```bash
     bestocr run "<input>" --doc-type <type> [--pages 1-3] --out "<workdir>"   # → <stem>.md
     ```
   - 轉檔(math-aware 選擇,PsychQuant/bestOCR#3):
     ```bash
     # 內容含數學且 pandoc 在 → 原生 OMath 公式
     pandoc "<workdir>/<stem>.md" -o "<workdir>/<stem>.docx"
     # pandoc exit 非 0 或產出無效 → 降回 macdoc + 字面限制聲明
     # 無數學,或 pandoc 缺席 → macdoc(公式為 LaTeX 字面)
     macdoc convert --to docx "<workdir>/<stem>.md"              # → 同目錄 <stem>.docx
     ```
   - **路徑安全**:優先走 MCP 參數(JSON 傳值,不經 shell 解析)。組 CLI 指令時
     危險在**把 raw 檔名直接內插進會被 shell 解析的 command 字串**——內插的
     `$( )`/反引號/`"` 會被執行或破壞語法;安全作法是經變數傳遞(`"$input"`
     的展開不會再觸發 command substitution)或 argv 介面。檔名以 `-` 開頭時
     用絕對路徑(或 CLI 支援的 `--`)。無法安全傳遞就先改名再處理。
   - doc-type 判斷同 `/bestocr:ocr`(掃描文件 → `scanned_doc`;數學密集加 `--math`)。
   - 批次策略:單檔失敗記錄後**繼續**下一檔,最後逐檔彙報成功/失敗。
5. **輸出檢查**(每檔):
   - 轉檔指令 exit status 成功;docx 是可開啟的 ZIP 且含 `word/document.xml`;非空。
   - 有數學內容時抽查公式(含 `$...$`、`$$...$$` 等 delimiter):**先看 md**——
     md 內公式已缺/亂 → OCR 端問題(引擎/routing);md 正確而 docx 缺/改寫 →
     **依實際轉檔器歸因**:走 pandoc → 記錄於 bestOCR issue(pandoc 版本一併附上);
     走 macdoc → 提議開 issue 到 PsychQuant/macdoc。歸因要分開,不混報。
6. **回報**:每檔的輸出路徑 + 使用引擎(fallback 鏈照轉述)+ 轉檔器聲明:
   - 走 pandoc → 「pandoc 可辨識的公式已轉為 Word 原生 OMath」
   - 走 macdoc 且內容含數學 → **限制聲明**:
     > 數學公式在 docx 內以 LaTeX 原文呈現(如 `$y = \beta_0 + \beta_1 x$`),
     > 非 Word 原生公式(pandoc 未安裝;裝 pandoc 可得原生公式)。

## 邊界

- **v1 docx-only**;pdf/pptx/html 等其他 macdoc 支援格式尚未納入(擴充另議)。
- OCR 品質由 bestOCR 引擎與 evidence routing 決定;轉檔忠實度由轉檔器(pandoc/macdoc)決定——
  問題分開歸屬(見步驟 5 的先後比對)。
- **cloud.`*` 不會被自動選中**:auto-routing 的候選來自 Recommender,其結構上
  排除 cloud reference 引擎(spec §6.1.3,有測試釘住)——只有使用者明說要
  cloud 比對時才用 `/bestocr:compare`,且文件會離機要先取得同意。
