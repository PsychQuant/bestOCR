# 2026-07-22 — P5:idd-all 批次(#3 OMath / #5 scanned evidence / #6 wrapper / #7 path-safety)

四題 direct-commit batch(conflict-class ordered:A 類先行,B 類壓軸)。

## #6 wrapper sidecar 版本記錄(bug)

- fallback 下載後 sidecar 改記**實際安裝版本**(從最終 URL 的
  `/releases/download/v<tag>/` 段決定性解析),不再錯記 DESIRED_VERSION。
  修掉「未來真發同號 binary 永不更新」的隱患。三種 URL 形狀 + 真實 API
  URL 解析驗證。

## #7 path-safety 移植(skill hardening)

- ocr + compare SKILL.md 補路徑安全段(MCP 參數優先、`$()`/反引號警語),
  對齊 #1 verify 後的 ocr-to;evidence-ingest 輸入為 run-id 非檔名,不適用。

## #3 OMath 公式升級(feature)

- ocr-to 轉檔器 math-aware 選擇:math 內容優先 **pandoc**($...$→
  `<m:oMath>` 原生公式,實測 7/7 元素、0 字面殘留),pandoc 缺席降回
  macdoc + 字面限制聲明。upstream native 支援 tracking:PsychQuant/macdoc#141。

## #5 scanned_doc 首批 T2 evidence

- 20 份本機掃描測試文件批次 run(glm-ocr q8_0 全中選,100 頁,
  3.5–7.8 s/頁)→ 人工 QC(20/20 thermal=fair,使用者裁決全數帶 caveat
  ingest)→ 20 筆 `speed.ms_per_page` T2 rows。
- 閉環:`recommend --doc-type scanned_doc --priority speed` 首次回 RANKED
  (引用 runlog row;其餘引擎誠實 unverified)。

## 版本

- plugin/marketplace 0.6.1(binary 未更新,仍 v0.5.1;本批同時含 runtime
  evidence 資料,非嚴格 shell-only)。

## Verify R2 修正(6-AI batch verify 後 fix-forward)

- **#6**:version-gap 下 wrapper 每次 spawn 重下載 48.5MB 的迴歸(sandbox
  實測證實)→ resolution-chain 版本比對跳過重下載;tmp 檔改 mktemp(並發
  spawn race);「final URL」註解措辭修正。
- **#3**:macdoc 改條件式必要(math+pandoc 環境不被擋)、pandoc 失敗降回
  macdoc、step 5 依實際轉檔器歸因、math 判定以 pandoc 可辨識 node 為準、
  plugin/marketplace description 的 literal-LaTeX 殘留句更新。
- **#5**:doc-type 詞彙正名——`scanned_doc` 為掃描類 canonical(docs 與
  CLI/MCP help 原教 `scanned_book`,與已 commit 的 20 筆 rows 對不上,
  使用者照文件查會 0 命中;evidence rows 依 provenance 紀律**不改**,
  改的是詞彙教學面);changelog 頁數修正 96 → 100(加總錯誤,Codex 抓到)。
- **#7**:quoting 措辭精確化(危險前提=raw 內插,`"$input"` 展開不會再觸發
  substitution)+ leading-dash `--` 指引;三個 skill 檔對齊。
