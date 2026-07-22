---
name: compare
description: 把本地 OCR 引擎與 cloud 參照(Claude/OpenAI/Gemini vision)在同一頁面上並排,回報 token recall(具名公式,非 ground truth)。當使用者說「這個引擎準不準」「跟 Claude 比一下 OCR 品質」「本地跟雲端差多少」時使用。需要對應的 API key env;文件會離開本機——執行前先跟使用者確認這點。
---

# compare — 本地引擎 vs cloud 參照

**執行前必說**:cloud 參照會把文件頁面送到第三方 API(文件離機)。使用者沒明確同意前不要跑。

## 流程

1. 確認:輸入檔、要比的本地引擎(`--engine`)、cloud 參照(`--vs cloud.claude`,預設)。
2. 確認對應 key 已設(`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY`),沒設就請使用者 export。
3. 跑:`bestocr compare <input> --engine <local> [--vs cloud.claude] [--doc-type ...] [--pages 1-3] [--out DIR]`
4. 回報兩側耗時、`quality.token_recall_vs_cloud@v1` 數值、兩份輸出檔路徑。
5. compare 會把本地側寫進 runlog(quality stat 附在該筆上)並印出 run id。
   若使用者想把這次比較記進證據,接 `/bestocr:evidence-ingest <run-id>`
   ——會同時升級 speed + quality 兩個 row(仍是人工閘門,不自動)。

## 路徑安全

- 組 `bestocr compare` CLI 指令時雙引號只擋空白/中文/括號,**擋不住**
  `$( )`、反引號、`"`、換行等——輸入檔名含這類字元時改用安全傳遞
  (避免把 raw 檔名內插進 shell 字串),或先改名再處理。

## 誠實邊界(必轉述)

- 這個指標的參照是**另一個模型的輸出**,不是 ground truth——**不可**與 `word_recall`(pdftotext/ABBYY 參照)混用或比較(evidence schema 硬規則)。
- 數值低可能是本地引擎差,也可能是 cloud 參照自己錯——需要人工抽查兩份輸出。
