# 2026-07-29 — P10:pipeline 觸達 agent + `ocr-to` 變薄殼 + v0.8.0

#24 把交付規則變成 code 之後,剩下的問題是**誰碰得到它**。這批把 `pipeline`
接到 MCP、把 skill 改成薄殼,並統一三個版本號發 v0.8.0。

## 為什麼一定要先補 MCP tool(不是「順便」)

原本的計畫是「把 `ocr-to` skill 改成委派給 `bestocr pipeline` CLI」。動手前查了
plugin wrapper —— **它只下載 `bestocr-mcp`,不裝 `bestocr` CLI**
(`plugins/bestocr/bin/bestocr-mcp-wrapper.sh`,`BINARY_NAME="bestocr-mcp"`)。

所以「skill 委派給 CLI」對**每一個用 plugin 安裝的使用者都會直接壞掉**:他們機器
上根本沒有那個指令。委派要成立,delegate 必須是 MCP tool。這是先做 `pipeline`
tool 的唯一理由,不是範圍膨脹。

## MCP `pipeline` tool

- 參數與 CLI 對齊(`input_path` / `input_paths`、`to`、`out_dir`、`engine`、
  `doc_type`、`document_class`、`priority`、`math`、`dpi`、`pages`、`lang`、
  `converter`、`overwrite`、`async`),沿用 `ocr` 的 single-flight 閘門與
  `ocr_status` / `ocr_result` 輪詢。
- 參數解析**在閘門之外**(與 `handleOCR` 同紀律):壞參數要立刻失敗,不該先排隊
  等別人的 OCR 跑完。
- **partial batch 一定是 error**:有任何一檔失敗就 throw,而 throw 的 message
  就是**整份報告** —— 這樣 `isError` 正確,同時一個字都沒少。
- 測試釘住三件事:真的產出通過驗證的 docx、**拒絕覆寫的保護有跨過 MCP 邊界**
  (agent 得到與人在 CLI 前一樣的保護)、缺參數是 loud error。

## `ocr-to` skill:83 行 → 薄殼

規則已經在 binary 裡,skill 再寫一次就是第二份實作。新版明確列出「binary 已經
保證的事」並要求**不要再手動做一次**(不要自己選轉檔器、組輸出路徑、檢查覆寫、
開 zip 驗),只留下 agent 真正該判斷的:

- 問清楚輸入與目標格式(v1 docx)、長文件的頁數範圍;
- **workload 判斷**——`doc_type`,以及 `document_class`(多欄/表格/混合才設,
  單欄不要設,per-page 引擎又快又夠用);
- 照 `pipeline` 的輸出**轉述**歸因,不重寫;
- 失敗時的歸因紀律:**先看 md**——md 就壞 → OCR 端;md 對而 docx 壞 → 依實際
  轉檔器分開報(pandoc → bestOCR issue;macdoc → macdoc issue),不混報。

## v0.8.0:三號統一

`BestOCRVersion.semver` / `plugins/bestocr/.claude-plugin/plugin.json` /
`.claude-plugin/marketplace.json` 的 `metadata.version` 全部 `0.8.0`。

順帶修掉一個漂移:v0.7.0 的 commit 訊息寫「kit + plugin + marketplace unified」,
但 `metadata.version` 其實留在 `0.6.2` 沒動。這次一起校正。

## 本次發布內容(v0.7.0 → v0.8.0)

- #16 document-assembly engines + document-class routing(PR #23)
- #24 `bestocr pipeline`(PR #26)
- 本批:MCP `pipeline` tool + `ocr-to` 薄殼 + 版本統一

## Residue

1. **`ext.surya` 用的是 0.17.1(舊版)**,而 marker 內部帶的是 surya **0.22.1**
   (surya-2,PyPI 最新)。兩個世代同時存在,而 `ext.surya` 的 evidence row 只記
   `model: "surya"`、**不帶工具版本** —— 0.17.1 與 0.22.1 的 row 在證據裡分不
   出來,和 `candidates.json` 的 `surya-2 (0.65B GGUF) T3` 條目也講的不是同一件
   事。升版與「把工具版本納入 condition tuple」是兩個獨立決定,刻意不夾在 release
   裡做,另開 issue 處理。
2. **v1 仍只支援 docx**;其他格式未納入。
3. `doc.paddleocr-pipeline` 端到端仍未實跑(本機無 paddleocr,見 P8 residue)。
