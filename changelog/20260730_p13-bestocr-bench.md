# 2026-07-30 — P13:bestOCR-bench 公共證據層(#33)

規劃案由使用者明示「直接做完」解除其自訂時機條款:spec(PR #34,`baaf09f`)
與 build-out 同日交付。新 repo:`PsychQuant/bestOCR-bench`(public)。

## 分工(spec 的一句話契約)

**bestOCR 保留儀器與本機證據迴路;bench 承擔公共跨機器聚合。**
沒有任何檔案離開 bestOCR —— `schema.md` 是 code/測試釘住的契約留在儀器側
(bench 放帶 banner 的 vendored copy);curated `rows.jsonl` 是儀器自己的
量測記錄,不遷移。`repos/measureOCR` 凍結儀器一字未動。

## 契約重點

- **Row = bestOCR 的 `EvidenceRow`**(estimand × condition tuple × tier
  原生攜帶)+ 4 個提交欄位;append-only 檔名
  `<UTC-basic>Z-<contributor>-<machine12>.jsonl`。
- **Tier 只鑄 `T2-community`**:新標籤,不重定義 T2、不誤標 T3;leaderboard
  只在該 tier 內、per-estimand 分表排名;**`recommend` v1 不消費 bench rows**
  (wrapper 續抓本 repo curated 檔)—— 社群數字永遠不會靜默轉動 auto-routing。
- **CI 驗證器**(stdlib-only,fixture 實測 + GitHub Actions 首推實跑均綠):
  hard rule 2 在 gate 擋未知 estimand;corpus_id 存在;bitwise 去重;值域
  per estimand family。軟標不擋:adapter-backed(platform=python)缺
  `tool_version` → warn(#28 的欄位在跨機器情境 load-bearing);3×MAD 群組
  離群 → 印給人審。
- **Corpus license gate** 照 bestASR-bench(CC0/CC-BY/CC-BY-SA/
  public-domain/own-consented + attribution;本體住 HF dataset)。CI 檢查
  不了「是否真的可再散布」—— 明文交給人審,不假裝驗證。
- **匯合點**:#16 spec §12 的可再散布標註參照子集 = bench corpus 首個住民,
  兩個 backlog 項一份工。

## Security baseline(建 repo 當日)

secret scanning + push protection + dependabot alerts 啟用;main branch
protection(no force-push / no deletion / linear history)。

## Residue

corpus 內容(需人工標註,自身的誠實問題)、`bestocr bench submit` 工具
(等 demand)、`recommend` 與 bench 聚合的關係(獨立決策)、LICENSE 檔
(bestASR-bench 對稱地也沒有 —— 資料授權 per corpus row,工具授權未宣告,
兩 repo 應一起補)。
