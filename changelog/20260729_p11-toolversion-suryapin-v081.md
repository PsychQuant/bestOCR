# 2026-07-29 — P11:#28 tool_version 入 condition tuple + #29 surya 世代 pin + v0.8.1

`/idd-all #17 #28 #29` 批次的 #28/#29 兩條 lane(PR #30 `df9aa4a`、PR #31
`273124f`),加 v0.8.1 版本統一(`d34e527`)。#17 由並行 session 實作中,
不在本 changelog 範圍。

## #28 — 量測工具版本進 condition tuple(bug/evidence contract)

- 根因三層:tuple 無欄位;protocol 的 `ProbeReply.version` 被 host 丟棄
  (且 probe-time 有 TOCTOU —— recognize 時 interpreter 重新解析);
  surya adapter 用 `__version__` 查版本而 0.17.x 根本沒有 → probe 回
  `"unknown"` 卻像查過了。
- 修法:版本坐**工作回覆**(`ocr`/`assemble` reply 的 `"version"`,由產出
  結果的那個 process 量測);兩個 adapter-backed engine 線進
  `ConditionTuple.toolVersion`(JSON `tool_version`,optional + defaulted
  → 零遷移,nil 省略 key → legacy 形狀逐位元不變)。五個 embedded adapter
  全部改用 dist metadata 報版本。
- schema.md §3 記欄位 + 誠實邊界:**記錄 ≠ 新排名規則**(排名粒度維持
  per-model-key,與 dpi/quant 現狀一致;要不要按版本分割排名是另一個
  estimand-semantics 決定)。
- 測試教訓:adapter fixture **不能叫 `<tool>.py`** —— adapter 內
  `import cnocr` 會 import 到 fixture 自己(module shadowing);
  用連字號檔名(與正式 materialize 命名一致)就不可能被 shadow。
- 實測:`ext.rapidocr` 真跑一次,runlog tuple 帶 `"tool_version":"3.6.0"`;
  surya probe 回 `0.17.1`。

## #29 — surya 世代決定:刻意 pin 0.17.x(decision → labels)

- 選項 (b):`ext.surya` **刻意留在 0.17.x classical det+rec 世代** ——
  它是 roster 唯一**免 model server** 的 OCR-tool fallback,正是
  llama-server 路徑壞掉時(#15)你要留著的那個能力;原地升級是唯一會
  「拿掉能力」的選項。
- 決定成為**會旅行的標籤**:`tradeoffNote` 進 `list-engines` 與每條
  `recommend` entry;install hint 改 `pip install "surya-ocr<0.20"`
  (裸裝今天會拿到 0.22.x,不是這個引擎);candidates.json 的 surya-2
  (T3)條目 cross-ref pin 決定,不會被誤讀成升級路徑。
- 決定出處誠實記錄:unattended 下以最小爆炸半徑假設自動採 (b)
  (Layer V deferred record),批次報告顯著標示後由使用者明示
  merge + close **人工批准**。選項 (c)(把 surya-2 收為獨立引擎)保留
  為 tracked 殘留 —— #28 合併後,未來 surya-2 的 rows 可機械區分。

## v0.8.1(`d34e527` + release)

- kit semver / plugin.json / marketplace(entry + metadata)三號統一 0.8.1;
  CLAUDE.md 測試數同步(**270 tests / 41 suites**,合併後 main 在隔離
  worktree 實測全綠)。
- release binaries 簽章 + notarize 後上傳(過程見 #28/#29 closing
  summaries 的 Distribution Sync 段)。

## 附註:共享工作樹紀律(本批次兩次實踐)

lane #17 由並行 session 在同一棵工作樹實作;本批次兩度讓路 —— 撤回自己
誤寫入的檔案、不切它的 branch、所有 main 端操作(版本 bump、suite 驗證、
release build)改走**臨時 git worktree**。本 changelog 也因此以 docs-only
commit 落在該 session 的 branch 上(新檔案、不可能衝突、內容只涉及已合併
的 #28/#29/v0.8.1),隨它日後的 PR 一起回 main。
