# 2026-07-21 — M1+M2:多平台引擎層、外部 adapter、tier 紀律 recommend

## 摘要

bestOCR 從純文件 scaffold 變成可運作的 Swift package:一天內落地 spec 的
M1(引擎層 + CLI)與 M2(external adapters + recommend)兩個里程碑。
全程 TDD(每個元件先寫 failing test),54 tests / 13 suites 全綠。

設計文件:

- spec:`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`
- M1 計畫:`docs/superpowers/plans/2026-07-21-bestocr-m1-engine-layer.md`
- M2 計畫:`docs/superpowers/plans/2026-07-21-bestocr-m2-adapters-recommend.md`

## M1 — 引擎層 + CLI(commits 15b8551…9a45efb)

- `Package.swift`:swift-tools 6.1、macOS 14+;products = `bestocr`(CLI)+
  `BestOCRKit`(library);依賴 ocr-swift 0.2.1 / pdf-to-latex-swift 0.1.0。
- `OCREngine` protocol:id / family / capabilities / `probe()`(不可用是值
  不是例外)/ `recognize()`。
- 每個 `OCRResult` 內建 evidence condition tuple(JSON key 與
  `evidence/schema.md` §3 逐字對齊,含 thermal state)。
- 引擎:`VisionEngine`(Apple Vision,永遠可用)、`TesseractEngine`
  (subprocess + timeout-safe `Subprocess` runner)、`VLMEngine`(Ollama,
  wrap ocr-swift `OllamaBackend`;`RepetitionGuard` 退化迴圈保險絲)。
- `ModelProfile`:模型怪癖集中地 — PaddleOCR-VL 強制 native `OCR:` prompt;
  預設 tag 活體校正為 SHA256-pinned `*-anova:q8_0`(nominal-8-bit,對齊
  measureOCR E2 慣例;機器上無裸 `ovisocr2`/`paddleocr-vl` tag)。
- `RunLog`:每次 run 寫 JSONL 溯源紀錄(`~/.bestocr/runlog.jsonl`,
  `BESTOCR_RUNLOG` 可覆寫)— 顯式 ingest 閘門(M4)的地基。
- CLI:`bestocr run <input> --engine <id>`、`bestocr list-engines`。

## M2 — External adapters + recommend(commits 743a815…13420d3)

- OCR protocol v1(移植 bestASR ExternalProcessEngine 模式):argv 陣列
  spawn(不經 shell)、只讀 stdout **最後一行** JSON(容忍模型下載噪音)、
  非零 exit + stderr tail 上浮、timeout。
- `ExternalToolEngine` + 三個 Python adapter(SPM resources,
  `Sources/BestOCRKit/Adapters/`):rapidocr、cnocr、surya。
  `BESTOCR_PYTHON` 可覆寫直譯器。
- **nougat 判定 defer**:本機安裝被困在 `~/.local/pipx/venvs/pip/`
  (python3.12,主環境 import 不到)且上游已封存;protocol 架構讓日後
  re-admission 只是丟一個 script。
- `EvidenceStore`:讀 `evidence/rows.jsonl`(缺檔 = 空 store = 誠實
  evidence-pending;壞行大聲報錯不跳過)。
- `Recommender` tier 紀律(schema.md 硬規則):單一 tier 內排名、T1 > T2、
  T3 永不排名、跨 tier 證據「surfaced but not rankable」、每個排名引用
  rows;無證據時退化為 capability filter 並明說「這不是排名」。
- CLI:`bestocr recommend --doc-type … [--math] [--priority quality|speed|balanced]`。
- Roster 增為 8 引擎,全部 probe ✓ available。

## 驗證

- `swift test`:54 tests / 13 suites 全過(含活體整合:tesseract 0.3s、
  rapidocr 1.2s、cnocr 8.7s、Vision 中英混排截圖、GLM-OCR q8_0 走 Ollama
  7.9s;surya 整合為 opt-in `BESTOCR_TEST_SURYA`)。
- `swift build -c release` 乾淨(Vision deprecation warning 如預期)。
- recommend 兩模式 CLI smoke 皆驗證(evidence-pending / T2 ranked + citation)。

## 過程教訓

- `swift test | tail && git commit` 在 zsh 下不安全:pipe 的 exit code 是
  tail 的 → 一次把失敗的 Recommender 測試 commit 進去(隨即以
  `set -o pipefail` 重驗、修復、amend)。之後驗證鏈一律 `set -o pipefail`。
- Recommender 的 `engineModelKey` 需要 namespace-prefix fallback
  (`vlm.glm-ocr` → `glm-ocr`),否則 row matching 依賴具體型別。
