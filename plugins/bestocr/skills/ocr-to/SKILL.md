---
name: ocr-to
description: 把 PDF/圖片 OCR 後轉成使用者指定的目標檔案格式(v1 支援 docx)——一次呼叫走完 normalize → 路由 OCR → 組裝 → 轉檔。當使用者說「把這個 PDF 轉成 Word」「掃描檔轉 docx」「OCR 完給我 Word 檔」時使用。轉檔器依內容自動選擇:有數學且 pandoc 可用時輸出 Word 原生 OMath 公式,否則走 macdoc(公式為 LaTeX 字面,會聲明)。
---

# ocr-to — PDF/圖片 → 目標格式檔案(v1: docx)

**這個 skill 是薄殼。** 交付流程與所有安全規則都在 `pipeline` 這一個呼叫裡,
skill 只負責「問清楚要轉什麼」與「照實回報」。不要在這裡重新實作任何一步。

## binary 已經保證的事(不要再手動做一次)

| 規則 | 由誰保證 |
|------|----------|
| 不寫進輸入檔所在資料夾(預設 `bestocr-out/`) | `pipeline` |
| 既有輸出**在跑 OCR 之前**就拒絕(要 `overwrite` 才覆寫) | `pipeline` |
| 批次同名檔加來源後綴,不互相覆寫 | `pipeline` |
| 有數學 → pandoc(原生 OMath);否則 macdoc | `pipeline`(pandoc 自己的 math 規則) |
| 產出驗證(真的是含 `word/document.xml` 的 ZIP) | `pipeline` |
| 轉檔失敗保留 markdown、記錄 hops | `pipeline` |
| 單檔失敗不中止批次 | `pipeline` |

**所以:不要自己選轉檔器、不要自己組輸出路徑、不要自己檢查覆寫、不要自己開 zip 驗。**
做了只會與 binary 的行為分歧。

## 流程

1. **問清楚**(先於任何 probe——不支援的請求不該先要求裝依賴):
   - 輸入:絕對路徑的 PDF 或圖片。資料夾 → 列舉後與使用者確認清單。
   - 目標格式:v1 只支援 `docx`。使用者沒指定 → 確認「輸出 docx 對嗎?」;
     要求其他格式 → 說明 v1 限制(PsychQuant/bestOCR#1 拍板),停止。
   - 長文件 → 與使用者確認頁數範圍(`pages`,如 `"1-3"`)。
2. **判斷 workload**(這是 skill 真正的判斷工作):
   - `doc_type`:掃描件 → `scanned_doc`;數學密集 → `math_pdf` 並加 `math: true`;
     多欄掃描 → `multicolumn_scan`。
   - `document_class`:**多欄 / 表格為主 / 混合版面** → `multi_column` /
     `tabular` / `mixed`。這會把候選限制成 document-assembly 引擎,並印出速度
     代價 —— 單欄文件**不要**設,per-page 引擎又快又夠用。
3. **一次呼叫**:
   - MCP(優先,plugin 內建、模型保溫):
     `pipeline` `{input_path 或 input_paths, to: "docx", doc_type, document_class?,
     math?, pages?, out_dir?, overwrite?}`,長文件加 `async: true` 再輪詢
     `ocr_status` / `ocr_result` 至 terminal state。
   - CLI fallback(MCP 未註冊 / server 連不上 / 呼叫在建立 job 前就失敗):
     ```bash
     bestocr pipeline "<input>" --to docx --doc-type <type> [--document-class multi-column] [--pages 1-3]
     ```
     **已取得 async job id 之後**的中斷 → 繼續輪詢或明確放棄,**不要**改用 CLI
     重跑(會重複 OCR)。
   - 組 CLI 指令時把檔名經**變數**傳(`"$input"`),不要把原始檔名內插進會被
     shell 解析的字串;檔名以 `-` 開頭時用絕對路徑。MCP 走 JSON 傳值,沒這問題。
4. **回報**(照 `pipeline` 的輸出轉述,不要重寫):
   - 每檔的輸出路徑、使用引擎、fallback hops、`converter:` 那行的歸因。
   - converter 是 macdoc 且內容有數學時,把限制講出來:
     > 數學公式在 docx 內以 LaTeX 原文呈現(如 `$y = \beta_0 + \beta_1 x$`),
     > 非 Word 原生公式(pandoc 未安裝;裝 pandoc 可得原生公式)。
   - 有 `run id` → 告訴使用者可以 `bestocr evidence ingest <id>` 把這次的速度
     測量升級成 T2 evidence。

## 失敗時怎麼歸因

`pipeline` 會保留 markdown。**先看 md**:

- md 內公式已缺/亂 → **OCR 端**問題(引擎或 routing),不是轉檔器。
- md 正確而 docx 缺/改寫 → 依 `converter:` 那行的實際轉檔器歸因:
  走 pandoc → 記錄於 bestOCR issue(附 pandoc 版本);走 macdoc → 提議開 issue 到
  `PsychQuant/macdoc`。**歸因要分開,不混報。**
- 拒絕覆寫 → 這是預期行為,不是 bug。問使用者要換輸出目錄還是 `overwrite`。

## 邊界

- **v1 docx-only**(#1 拍板);其他 macdoc 支援的格式尚未納入。
- OCR 品質由引擎與 evidence routing 決定;轉檔忠實度由 pandoc/macdoc 決定——
  問題分開歸屬(見上一節)。
- **cloud.`*` 不會被自動選中**:auto-routing 的候選來自 Recommender,其結構上
  排除 cloud reference 引擎(spec §6.1.3,有測試釘住)。只有使用者明說要 cloud
  比對時才用 `/bestocr:compare`,且**文件會離機**,要先取得同意。
