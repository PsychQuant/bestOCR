<!-- SPECTRA:START v1.0.2 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra-*` skills when:

- A discussion needs structure before coding → `/spectra-discuss`
- User wants to plan, propose, or design a change → `/spectra-propose`
- Tasks are ready to implement → `/spectra-apply`
- There's an in-progress change to continue → `/spectra-ingest`
- User asks about specs or how something works → `/spectra-ask`
- Implementation is done → `/spectra-archive`
- Commit only files related to a specific change → `/spectra-commit`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra-apply` and `/spectra-ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

# bestOCR — agent notes

Evidence-based OCR router(bestASR 的 OCR sibling)。README 是產品說明;
本檔是 agent 工作備忘。設計 spec 在
`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`(M1–M4
里程碑、四件套介面、evidence 紀律)— 動架構前先讀它。

## Build / Test

```bash
swift build            # debug;release 加 -c release
swift test             # 304 tests / 46 suites;Swift Testing(import Testing),不是 XCTest
```

- **需要 Swift 6.3+**(transitive `mlx-swift` 的 tools-version floor)。repo 內
  的 `.swift-version` 寫死 `xcode`,讓 swiftly 使用者在本 repo 解析到 Xcode
  toolchain。若 `swift build` 報 `mlx-swift ... using Swift tools version
  6.3.0 but the installed version is <舊>`,**先跑 `type -a swift`** —— 通常
  不是缺 toolchain,而是版本管理器的 shim 排在 `/usr/bin` 前面把它遮住了
  (#19)。詳見 README「CLI install」段。
- 驗證鏈一律 `set -o pipefail`:`swift test | tail` 的 exit code 是 tail 的,
  沒有 pipefail 會把失敗測試放行(20260721 changelog 記錄的實際事故)。
- 整合測試設計:工具缺席 → 測試內 probe + 早退(印 `SKIP:`),絕不假通過;
  surya 整合另需 `BESTOCR_TEST_SURYA=1`(首跑下載 ~GB 模型),
  `doc.*` 端到端另需 `BESTOCR_TEST_DOCPIPELINE=1`。
- **端到端 suite 要 `@Suite(.serialized)`**:會經 AppKit/CoreGraphics 渲染
  fixture + 跑 Vision + spawn 子行程的測試 fan out 到平行 runner 會把整個
  process 卡住(`PipelineFlowTests` 踩過:263 started / 39 done,`--no-parallel`
  17 秒全綠)。`swift test` 卡住時**先跑 `--no-parallel`** 分辨「測試錯」還是
  「併發錯」。另外測試內**不要 `setenv`** —— 與其他測試併發的 `getenv` 不安全,
  改用注入(見 `PipelineFlow.locateConverter`)。
- embedded Python adapter **要當 Python 測**:`py_compile` + 用 fixture JSON
  驅動 adapter 自己的函式(見 `DocumentPipelineEngineTests`)。這樣工具沒裝
  的機器也能覆蓋 adapter 邏輯,而不是整段沒測。

## 架構速覽

```
Sources/BestOCRKit/        引擎層(protocol、Registry、RunLog、RunPipeline)
  Engines/                 VisionEngine / TesseractEngine / VLMEngine /
                           ExternalToolEngine / DocumentPipelineEngine
                           (+ Subprocess、ModelProfile)
  Adapters/                AdapterProtocolV1(共用 protocol)+ AdapterScripts /
                           DocumentAdapterScripts(embedded Python,非 resource)
  DocumentStructure.swift  DocumentStructure / DocumentBlock / §4.3 invariant
  Recommend/               WorkloadSpec(+DocumentClass)/ EvidenceStore /
                           Recommender / Estimand / StructureMetrics
  Convert/                 MarkdownMath(pandoc 規則)/ FileConverter /
                           DocxValidator / OutputPlanner(防覆寫)
  PipelineFlow.swift       input → deliverable 串接(#24)
  Triage/                  測量式分診(#35):TriageProbe(per-page 文字層+
                           碎片密度)/ TriageDivergence(抽取方法 informant
                           對,只復用 ItemExtractor/alignment)/ TriageRunner
                           (async divergence wiring)。閾值 env:
                           `BESTOCR_TRIAGE_TEXT_MIN` / `BESTOCR_TRIAGE_FRAG_MAX`
                           (evidence-pending,單樣本歸納)
  Consensus/               ItemExtractor / ConsensusAlignment / Pipeline /
                           ConsensusAdjudicator(protocol + registry)/ 六個
                           adjudicator(ds-lite/majority/ds-full/
                           prior-weighted/irt/rover;#17)
Sources/bestocr/           CLI 薄殼(run / pipeline / list-engines / recommend /
                           compare / consensus / evidence)
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
- **marker `--mode` 預設隨裝置**(`marker/config/parser.py` 實證):GPU 走
  `balanced`(VLM layout),**CPU/MPS 走 `fast`(CPU layout detector)**。#15
  的 layout grammar 全滅是明確傳 `--mode balanced` 才踩到的;marker 在 Apple
  Silicon **不是天生 layout 壞掉**。`doc.marker` adapter 因此刻意不傳
  `--mode`(讓 marker 取裝置預設),`BESTOCR_MARKER_MODE` 可覆寫。
- **assembly adapter 的計時契約**(`AssembleInvocation`):有 Python pipeline
  物件的(paddle)load 一次 → 逐頁 warm 計時 + `load_seconds` 分開報;只有
  CLI 的(marker)每次 invoke 重載 → 由 host 計時。**絕不**用 batch 總時間
  除頁數(看起來像 per-page 其實沒量到)。
- **nougat deferred**:安裝困在 pipx venv、上游封存;要 re-admit 就補一個
  adapter script + wiring(參考 rapidocr adapter)。
- MLX serving path 等 mlx-swift-lm 上游修復(measureOCR KNOWN-ISSUES #4)。

## 里程碑狀態

- ✅ M1 引擎層 + CLI、✅ M2 adapters + recommend(2026-07-21)
- ✅ M3 MCP server + plugin + notarize(2026-07-22;release v0.3.0)
- ✅ M4 cloud reference + `compare` + `evidence ingest`(2026-07-22)
- ✅ P2 auto-routing(預設)+ fallback chain + workflow skills(2026-07-22;
  v0.4.0)。repo 已公開 + security baseline 全綠;plugin 已實裝驗證
- ✅ P3 quality-estimand ingest(compare → runlog quality stat → ingest 雙
  row;recommend word_recall 優先、token_recall fallback、絕不混排)+
  PaddleOCR-VL `\( \)` → `$` Y3 正規化(profile-gated,只轉成對)(2026-07-22)
- ✅ P4 `/bestocr:ocr-to` skill(OCR → docx via macdoc CLI;純 skill 層,
  plugin 0.6.0 plugin-shell-only bump(skill 層,binary 不動)——wrapper 對缺 tag 版本 fallback 到
  releases/latest;math 純文字直通,OMath 升級見 #3)(2026-07-22,#1)
- ✅ P5 idd-all 批次(2026-07-22,plugin 0.6.1):#6 wrapper sidecar 記實際
  版本 + version-gap 防重下載;#7 path-safety 三 skill 對齊;#3 ocr-to
  math-aware 轉檔(pandoc → 原生 OMath,macdoc fallback;上游 macdoc#141);
  #5 首批 scanned_doc T2 evidence(20 rows,`scanned_doc` 為掃描類 canonical
  詞彙)。follow-ups:#8 sha256、#9 evidence 觸達、#10 版本字串
- ✅ P6 idd-all 批次 2(2026-07-22,**v0.6.2 release**——kit/plugin/marketplace
  三號統一,version-gap 終結):#8 wrapper sha256 驗證(404-body 假陽性
  gate);#9 evidence 觸達(defaultURL 三層鏈 → `~/.bestocr/evidence.jsonl`,
  wrapper 順抓 rows;ingest write-path 解耦);#10 版本字串由 semver 派生
- ✅ P7 consensus chain(2026-07-23,PR #14 merge `963cad7`):#11 多引擎
  CCT/Dawid-Skene-lite 共識(canonical vote labels、per-kind competence、
  agreement 診斷、`converged`+cap-reversal);#12 evidence 整合(composite
  runlog entry、`speed.ensemble_ms_per_page@v1` 獨立 estimand never-mix);
  #13 robustness hardening(placeholder 棄權、gap-interval solo 合併、
  資源上限、cloud/needsNetwork 拒絕、`schema_version: 2`)。171/171 tests
- ✅ P8 document-assembly engines + document-class routing(2026-07-28,#16;
  spec `docs/superpowers/specs/2026-07-28-document-assembly-engines.md` 由
  PR #21 先進 main):`OCRResult.document`(optional,reading order = blocks
  陣列順序)、`EngineCapabilities.assembly`、`doc.paddleocr-pipeline` /
  `doc.marker`、`DocumentClass` routing + 成本揭露、`tradeoffNote`、
  estimand 版本化相容(`Estimand.canonical`)。兩個 assembly estimand
  **有公式、刻意無數字**(缺可散布的人工標註參照集)。224/224 tests
- ✅ P9 `bestocr pipeline`(2026-07-28,#24):normalize → route → OCR →
  assemble → convert 單一指令。**`ocr-to` skill 的安全規則變成 code**:預設輸出
  到獨立 `bestocr-out/`、既有輸出**在跑 OCR 之前**就拒絕(`--overwrite` 才過)、
  批次同名 stem 對稱加後綴、docx 驗 ZIP + `word/document.xml`(exit 0 不算證據)、
  math 判定用 **pandoc 自己的規則**(開頭 `$` 右邊非空白、結尾 `$` 左邊非空白且
  後面不是數字 → `$5 and $10` 是貨幣不是公式)。follow-up:skill 改成薄殼委派
  給這個指令(要 plugin bump,故不在 #24 scope)
- ✅ P10 pipeline 觸達 + v0.8.0 release(2026-07-29):MCP `pipeline` tool
  (**必要**——plugin wrapper 只裝 `bestocr-mcp` 不裝 CLI,skill 若委派給 CLI
  對 plugin 使用者會直接壞);`ocr-to` skill 改成薄殼(規則已在 binary,skill
  只留 workload 判斷與歸因);kit/plugin/marketplace 三號統一 0.8.0
- ✅ P12 pluggable consensus adjudicators(2026-07-29,#17,PR #32 由並行
  session 實作):`ConsensusAdjudicator` seam + `AdjudicatorDiagnostics`
  (**nil = 無此概念、[:] = 有概念但無可報** —— 別混);六個 adjudicator 經
  `--adjudicator` / `--list-adjudicators`(tradeoffs 絕不排名);estimand 依
  adjudicator 資格化 `consensus.<id>.<quantity>@v1`(legacy 無資格名讀作
  ds-lite);full-DS 是**字元級** confusion(`rn`→`m` 不可表示,型別內揭露);
  Bayesian CCT/GCM **刻意未建**(沒有 sampler 就不掛那個名字)。304/46 tests
- ✅ P13 bestOCR-bench 建立(2026-07-30,#33;spec `docs/superpowers/specs/
  2026-07-30-bestocr-bench.md` 先進 main):公共證據層 sibling repo
  (`PsychQuant/bestOCR-bench`)——corpus(license-gated)/ measurements
  (**tier 只鑄 T2-community**)/ leaderboard / 提交 CI(hard rule 2 在
  gate 擋未知 estimand;adapter-backed 缺 `tool_version` 軟警告;3×MAD 軟
  離群)。schema.md **canonical home 留本 repo**,bench 放帶 banner 的
  vendored copy;`recommend` v1 **不消費** bench rows。
- ✅ P14 triage 單一入口(2026-08-03/04,#35,**v0.10.0 release**;openspec
  change `triage-single-entry` archived,main specs 首版 = `triage` +
  `ocr-single-entry`):測量式分診 —— per-page 文字層/碎片密度/divergence
  三 task、三路徑(text_direct / render_suspect_pages / ocr_full / mixed)、
  `triage` CLI+MCP、`ocr` skill 單一入口化、`triage.route_accuracy@v1`
  estimand(defined-unmeasured)。spec §5.2 的 born-digital 重 OCR accepted
  cost 被推翻(§12 revisit)。336→ 最終 tests 全綠;verify 抓到空頁選擇
  trap(修為顯式 degraded)。sister:bench#1(estimand gate 同步,已 closed,
  schema §3 增 triage thresholds 條款 `f6f1b24`)+ bench#2 self-test 套件
- Backlog:assembly estimand 的標註參照子集(spec §12,**= bench corpus 的
  第一個住民**,同一份工;triage 閾值校準同批標註)、MLX serving path(上游)、
  **triage evidence ingest**(estimand 有 rows 之前不動;屆時 `ConditionTuple`
  需擴 `triage_text_min`/`triage_frag_max` 欄位以對齊 schema §3 `f6f1b24` —
  bench validator 已 enforce,kit 端 ingest 不同步會產出被 bench 拒收的 rows)

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
