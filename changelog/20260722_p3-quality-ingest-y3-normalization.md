# 2026-07-22 — P3:quality-estimand ingest + PaddleOCR-VL Y3 delimiter 正規化

M4 記錄的兩個 deferred backlog 項目收尾。

## Quality-estimand ingest

- **`RunLogEntry.QualityStat`**(optional 欄位,舊 runlog 行照常 decode;
  nil 不寫 key,新舊 binary 互讀):estimand(具名版本化公式)、value、
  reference(哪個 cloud engine/model 當參照)。
- **`compare` 寫 runlog**:本地側 run 附 quality stat 落地,印出 run id +
  ingest 提示。cloud 參照本身仍不進 runlog、不進排名。
- **`evidence ingest` 雙 row**:speed.ms_per_page 照舊;該筆帶 quality stat
  時額外產 `quality.token_recall_vs_cloud@v1` row(T2),caveat 自動標明
  「reference = <cloud>/<model> — a cloud model output, not ground truth;
  not comparable to word_recall」(schema 硬規則 2)。
- **Recommender estimand 偏好序**:quality/balanced 先找
  `quality.word_recall`,完全沒有才 fallback 到
  `quality.token_recall_vs_cloud@v1`;單一 estimand 承載整個排名,絕不混排
  (新增測試釘住:word_recall 在場時 token_recall rows 不得參與排名;
  speed 永不借 quality 數字)。entry note 具名使用的 estimand。

## PaddleOCR-VL `\( \)` → `$` 正規化(Y3)

- **`MathDelimiterNormalizer`**:純掃描器。只轉換**成對**的 `\( \)` → `$ $`
  與 `\[ \]` → `$$ $$`(display 可跨行);不成對的 delimiter 原樣保留;
  `\\`(LaTeX 矩陣換行等)視為 escape 單位消耗,絕不誤讀為 delimiter
  (含 `\(a\\\)` 這種結尾 row-break 的窗台案例)。
- **Profile-gated**(spec §8「怪癖住在 profile」):`ModelProfile` 新增
  `normalizesMathDelimiters`,只有 paddleocr-vl 開;glm-ocr / ovisocr2
  已輸出 `$`,絕不重寫。
- **`VLMEngine.postprocess`**:後處理抽成可測函數;repetition fuse 讀
  raw(正規化不得遮掩 degenerate loop),再做正規化 + WARN 標記。
- 命名由來:Y3 = measureOCR 的 $-density estimand——PaddleOCR-VL 不正規化
  則 $-density 恆為 0,跨引擎不可比(candidates.json caveat)。

## 工作區整理

- `repos/measureOCR` submodule checkout 退回 article 1 凍結 pin
  `3f8f5ab`(儀器 repo 自身已前進到 b101fdb,但 bestOCR 端的 pin 變更
  屬於 article 端 pre-registration deviation,不隨手夾帶)。
- `*.code-workspace` 進 `.gitignore`。

## 驗證

- `swift test`:111 tests / 21 suites 全過(P3 新增 22:normalizer 12、
  VLM postprocess/profile 4、quality ingest 2、runlog 相容 1、recommender
  偏好序 3)。
- skills 文件同步:`/bestocr:compare` 加 run-id → ingest 銜接步驟;
  `/bestocr:evidence-ingest` 邊界改寫(speed-only 限制解除)。
