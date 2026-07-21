# bestOCR — agent notes

Evidence-based OCR router(bestASR 的 OCR sibling)。README 是產品說明;
本檔是 agent 工作備忘。設計 spec 在
`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`(M1–M4
里程碑、四件套介面、evidence 紀律)— 動架構前先讀它。

## Build / Test

```bash
swift build            # debug;release 加 -c release
swift test             # 54+ tests;Swift Testing(import Testing),不是 XCTest
```

- 驗證鏈一律 `set -o pipefail`:`swift test | tail` 的 exit code 是 tail 的,
  沒有 pipefail 會把失敗測試放行(20260721 changelog 記錄的實際事故)。
- 整合測試設計:工具缺席 → 測試內 probe + 早退(印 `SKIP:`),絕不假通過;
  surya 整合另需 `BESTOCR_TEST_SURYA=1`(首跑下載 ~GB 模型)。

## 架構速覽

```
Sources/BestOCRKit/        引擎層(protocol、Registry、RunLog、RunPipeline)
  Engines/                 VisionEngine / TesseractEngine / VLMEngine /
                           ExternalToolEngine(+ Subprocess、ModelProfile)
  Adapters/*.py            OCR protocol v1 Python adapters(SPM resource)
  Recommend/               WorkloadSpec / EvidenceStore / Recommender
Sources/bestocr/           CLI 薄殼(run / list-engines / recommend)
repos/measureOCR           ❄️ 凍結儀器(article 1 pin)— 絕不修改
evidence/                  schema.md(先讀)、candidates.json、rows.jsonl(未來)
```

## 鐵律

1. **`repos/measureOCR` 凍結**:article 1 pin 住,任何修改都需要 article 端
   的 pre-registration deviation note。產品需要的邏輯(如 parsePages)是
   「複製過來」不是 import。
2. **Evidence 紀律**(`evidence/schema.md`):排名絕不跨 tier;T3 永不排名;
   排名必引用 rows;無證據時 recommend 說「capability filter, not a
   ranking」。`ConditionTuple` 的 JSON keys 與 schema §3 逐字對齊
   (`doc_type` 不是 `docType`)。
3. **引擎只看頁面影像**(spec §5.2):PDF 由 InputNormalizer 用 PageRenderer
   轉頁;引擎不自己碰 PDF。
4. **Probe 先於派工**:不可用 = 值(`EngineAvailability.unavailable(reason:
   installHint:)`),附可執行的安裝提示。

## 模型 / 平台備忘

- VLM 預設 tag 是本機 SHA256-pinned build:`glm-ocr-anova:q8_0` /
  `ovisocr2-anova:q8_0` / `paddleocr-vl-anova:q8_0`(nominal-8-bit,對齊
  measureOCR E2)。機器上**沒有**裸 `ovisocr2` / `paddleocr-vl` tag。
- **PaddleOCR-VL 必須用 native `OCR:` prompt**(candidates.json caveat:
  generic prompt → 退化迴圈);怪癖一律寫進 `ModelProfile`,不散落呼叫端。
- OCR protocol v1(bestASR 模式):argv spawn、stdout 最後一行 JSON、
  非零 exit + stderr;env 覆寫:`BESTOCR_PYTHON` / `BESTOCR_RUNLOG` /
  `BESTOCR_EVIDENCE`。
- **nougat deferred**:安裝困在 pipx venv、上游封存;要 re-admit 就補一個
  adapter script + wiring(參考 rapidocr adapter)。
- MLX serving path 等 mlx-swift-lm 上游修復(measureOCR KNOWN-ISSUES #4)。

## 里程碑狀態

- ✅ M1 引擎層 + CLI、✅ M2 adapters + recommend(2026-07-21)
- ✅ M3 MCP server + plugin + notarize(2026-07-22;release v0.3.0)
- ✅ M4 cloud reference + `compare` + `evidence ingest`(2026-07-22)
- ✅ P2 auto-routing(預設)+ fallback chain + workflow skills(2026-07-22;
  v0.4.0)。repo 已公開 + security baseline 全綠;plugin 已實裝驗證
- Backlog:quality-estimand ingest、PaddleOCR-VL `\( \)` → `$` 正規化(spec Y3)

## Cloud reference 備忘(M4)

- `cloud.claude` / `cloud.openai` / `cloud.gemini`:probe 由
  `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` 閘控;
  **永不進 recommend 排名**(Recommender 過濾 `.cloudReference`,有測試釘住)。
- 模型預設(env 可覆寫):`claude-opus-4-8`(`BESTOCR_CLAUDE_MODEL`)、
  `gpt-4o`(`BESTOCR_OPENAI_MODEL`)、`gemini-2.5-flash`(`BESTOCR_GEMINI_MODEL`)。
- compare 指標是 `quality.token_recall_vs_cloud@v1` — cloud 是參照不是
  ground truth,**與 word_recall(pdftotext 參照)不可混用**。
- MCP binary 發佈:`make release-signed` → `gh release create vX.Y.Z` 附
  binaries + sha256;plugin wrapper 從 release 自動下載(版本讀 plugin.json)。
