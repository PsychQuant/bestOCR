# 2026-07-22 — P6:idd-all 批次 2(#8 sha256 / #9 evidence 觸達 / #10 版本字串)

三題 direct-commit batch(#10 → #8 → #9,C 類 #9 壓軸)。

## #10 BestOCRVersion.string 派生(bug)

- `string` 曾寫死 `"bestocr 0.1.0-dev"` 與 semver 脫鉤,所有 evidence rows
  的 `instrument` 欄位失真 → 改由 `semver` 派生(TDD 釘住派生關係);
  舊 rows 不回填(instrument 隨版本變屬預期)。

## #8 wrapper sha256 驗證(security hardening)

- 下載後抓 `${URL}.sha256` sidecar 比對:**mismatch → 丟棄 + 保留既有
  binary**(無既有 → exit 1);sidecar 抓取失敗 → warn-and-proceed
  (可用性取捨,mismatch 才是攻擊/損毀訊號);quarantine strip 移到驗證
  通過之後。真實 sidecar 抓取 + 竄改拒絕路徑實測。

## #9 evidence 對 installed 使用者的觸達(architecture,路線 1 拍板)

- `EvidenceStore.defaultURL()` 解析鏈:env → CWD `evidence/rows.jsonl`
  (存在才用)→ **`~/.bestocr/evidence.jsonl`**(新第三層;TDD 3 測試)。
- wrapper 於 binary 下載時 best-effort 抓 repo 的 rows(raw.githubusercontent,
  first-char JSON 檢查防 HTML 錯誤頁,失敗不擋)→ 使用者端 recommend
  脫離恆 evidence-pending。實測:raw 抓取 20 rows OK。
- 更新頻率綁 binary 下載事件為 v1 取捨(residue 記錄)。

## 信任邊界揭露(#9,刻意決定)

- evidence 抓取來源是 **mutable `main`**(raw.githubusercontent),與 #8 的
  release-tag + sha256 binary 路徑是不同信任邊界——刻意取捨:evidence 持續
  累積、與 release 解耦;rows 只被用於字串比對排名(無 code/path 消費面),
  最壞情況是排名被操縱,非執行面風險(verify DA 溯源確認)。

## Verify R2 修正(6-AI batch verify 後 fix-forward)

- **#8**:sidecar 404 body "Not Found" 非空 → 誤判已取得 hash → 必然
  mismatch 假陽性(fresh install 直接失敗)——加 `^[0-9a-f]{64}$` regex gate
  (兩個 GitHub domain 的 404 body 皆實測)。
- **#9**:ingest write-path 與 read 鏈解耦(`ingestTargetURL`,無 existence
  gate——CWD 檔暫缺時不再靜默寫到 ~/.bestocr;TDD 2 測試);wrapper evidence
  refresh 收斂單一成功鏈(成功訊息只在真成功、防 target 為目錄的 mv 陷阱)。
- 已知限制(記錄):evidence 檔若落地後損壞,load 依設計 loudly fail,
  自我修復要等下次版本變動的 refresh 或手動刪檔——與 refresh 頻率同屬
  residue,實用中踩到再升級。

## 後續

- 批次 verify 後發 **v0.6.2 binary release + plugin 同號 bump**(使用者拍板)
  ——終結 #6 發現的 version-gap,並把 P5/P6 的 Swift 變更送達使用者。
