---
name: evidence-ingest
description: 把一筆 runlog 紀錄顯式升級為 T2 evidence row(speed.ms_per_page),讓之後的 recommend/auto-routing 有測量依據。當使用者說「把這次 run 記進證據」「ingest 這筆」「讓 recommend 認得這個速度」時使用。這是人工品管閘門——絕不自動、絕不批次盲目 ingest。
---

# evidence-ingest — runlog → T2 證據(顯式閘門)

bestOCR 的每次 run 都寫 runlog(`~/.bestocr/runlog.jsonl`),但**不會**自動變成證據。這個 skill 是那道人工閘門(spec §6.2)。

## 流程

1. **找目標 run**:使用者指名 run id,或 `tail ~/.bestocr/runlog.jsonl` 列最近幾筆讓使用者挑(顯示 engine、doc_type、每頁秒數、thermal)。
2. **品管檢查**(這是閘門存在的意義,替使用者把關並口頭確認):
   - thermal 全 nominal 嗎?(非 nominal 會自動記 caveat,但值得提醒)
   - doc_type 標得對嗎?(錯的 doc_type 會污染該 workload 的排名)
   - 這次 run 有代表性嗎?(背景在跑重活的 run 別 ingest)
3. **執行**:`bestocr evidence ingest <run-id>`(id 可用唯一前綴)。
4. **驗證閉環**:跑 `bestocr recommend --doc-type <該型別> --priority speed`,確認新 row 出現在 RANKED 排名並引用 `runlog:<id>`,回報給使用者。

## 邊界

- M4 只 ingest `speed.ms_per_page`(quality 需要 runlog 沒有的 ground-truth 參照)。
- T1 永遠只來自 pre-registered sweep,不經此路。
- rows 落在 `evidence/rows.jsonl`(`BESTOCR_EVIDENCE` 可覆寫)。
