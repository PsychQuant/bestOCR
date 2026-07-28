# 2026-07-28 — P8:document-assembly engines + document-class routing(#16)

#15 的評估結論(Option A)落成產品能力。設計 spec 先以 PR #21 進 main
(`docs/superpowers/specs/2026-07-28-document-assembly-engines.md`),本批次是
spec 的 phase 0 → 5 全數實作。**224 tests / 34 suites 全綠。**

## Phase 0 — result shape(不可逆決定 1)

- `OCRResult` 加 optional `document: DocumentStructure?`(而非 sibling
  `DocumentResult` + 第二個 protocol):`RunPipeline` / `RunLog` /
  `EvidenceIngest` / `ConsensusPipeline` 全都消費 `OCRResult`,而 `AutoRouter`
  必須**跨** per-page/assembly 邊界 fallback——protocol 分裂會把那個 branch
  推進 router 本身。
- **reading order 就是 `blocks` 的陣列順序**,刻意不另設 index:兩份同義資料
  一定會漂移,而順序正是這類引擎唯一的產物。
- `BlockKind` 自訂 `init(from:)`,未知標籤降級 `.other`。預設 `Codable` enum
  遇到沒見過的 rawValue 會讓**整個** `OCRResult` 解不出來——upstream 多吐一個
  label 就會讓使用者過去封存的 `*.meta.json` 全部讀不回來。
- §4.3 invariant 成為 public property `documentContentMatchesPages`:blocks 與
  pages 的**內容**必須一致(順序可不同——重排正是 assembly 的目的),丟內容
  就是 adapter 壞了。這是唯一能抓到「測試會過但輸出有洞」的性質。

## Phase 0b — evidence contract(不可逆決定 2)

- **document-class 不進 `ConditionTuple`**。`doc_type` 本來就是 corpus-class
  欄位且已是自由 `String`,所以新增**值**(`multicolumn_scan`、`tabular_doc`)
  即可表達,**零遷移**。query 軸放 `WorkloadSpec`——tuple 記錄「量到什麼」,
  不是「誰要求什麼」。
- 順手修掉既有不一致(schema.md 用無版本名、code/README 用 `@v1`):schema
  改以 `name@vN` 為正式形式 + 相容行。**相容不能只寫在文件裡** ——
  `Estimand.canonical(_:)` 讓它在 code 裡成立,否則舊的 `speed.ms_per_page`
  row 與新 ingest 的 `speed.ms_per_page@v1` 會被當成兩個 estimand,一個排名
  裂成兩個。實測:committed 的 20 筆無版本 rows 仍正常 RANKED。

## Phase 1 — capability axis

- `EngineFamily.documentPipeline`(additive case,decode-safe)。
- `EngineCapabilities.assembly: AssemblyCapability = .none`(defaulted)——14 個
  既有 construction site 一行不動,且語意不變。
- 刻意**不**重用 `OutputLevel`:那是文字保真度軸,marker 就是反例(吐
  `mathMarkdown` 卻能把頁首插進題目中間),混軸會讓 routing predicate
  寫不出來。

## Phase 2 — 兩個 estimand(定義,刻意未量測)

- `quality.reading_order_tau@v1`:Kendall tau-b。**未配對的 block 另計、
  不進係數** ——把它折進去會把 *detection* 失敗混成 *ordering* 分數。
  matching 是 greedy one-to-one on Dice/character-bigram,threshold 0.60
  (threshold 是公式的一部分,所以寫進 schema.md)。
- `quality.table_structure_f1@v1`:cell-level F1 over `(row, col, text)`。
  選 cell-level 是為了 graceful degradation,也因為它**正確描述** paddle 的
  已知怪癖:多出來的假 table 掉 precision、不動 recall。
- 兩者都**沒有數字**:需要人工標註的參照子集,而 bestOCR 沒有,#15 的語料是
  第三方素材也不能拿來當。仍然實作成 code + hand-computed 測例,因為只活在
  散文裡的公式無法被檢查(schema hard rule 2)。
- 分母為 0 的比率回 `nil` 不回 0:0 是「無相關/全錯」的**主張**,跟「未知」
  是兩件事。

## Phase 3 — 兩個引擎

- `DocumentPipelineEngine` + protocol-v1 `assemble` 指令(embedded adapters,
  沿用 M3 單一 binary 的 materialize 模式)。protocol 的共用部分抽成
  `AdapterProtocolV1`(兩種 adapter-backed engine 之後,複製一份就是第二個
  漂移點)。
- **`AssembleInvocation` 是誠實度而非風格**:能拿到 Python pipeline 物件的
  工具(paddle)可以 load 一次、逐頁**warm** 計時,正是
  `speed.ms_per_page@v1` 的定義;只有 CLI 的工具(marker)每次 invoke 重載
  模型,沒有 warm 的 per-page 時間可報,所以由 host 計時、數字誠實地含那次
  重載。**絕不**拿 batch 總時間除頁數——那看起來像 per-page 其實什麼都沒量。
- iron law(spec §5.2)不破:adapter 只收頁面影像,不碰 PDF。因此跨頁組裝
  本來就在 scope 外——這兩個引擎加的是**頁內** reading order 與 table
  structure,而那正好是 #15 量到的失敗(頁首插進內文中間)。
- Python 當 Python 測:`py_compile` + 用 fixture marker-JSON 驅動 adapter 自己
  的 `leaf_blocks`,所以 KIND_MAP、數學處理、table-HTML 直通、bbox 正規化在
  「兩個工具都沒裝」的機器上都有覆蓋。live 端到端走
  `BESTOCR_TEST_DOCPIPELINE=1` opt-in(比照 surya)。
- table block 保留原生 HTML 而不轉 markdown pipe table:轉換會靜默丟掉
  colspan/rowspan,一個有損的表格比一個誠實的表格更糟。

### 對 #15 結論的**更正**(讀 marker 2.0 原始碼後的新發現)

`marker/config/parser.py`:`--mode` 是 `balanced | fast`,**預設隨裝置**——
GPU 用 balanced,**CPU/MPS 用 fast**,而 fast「用輕量 CPU detector 做
layout/table」。#15 是明確傳 `--mode balanced` 才踩到 surya 的
`json_schema` → GBNF grammar 失敗。

也就是說:**marker 在 Apple Silicon 不是天生 layout 壞掉,是被強制進
balanced 才壞。** #15 的發現對 balanced 成立,不構成對 marker 在 Mac 的
全面判決。adapter 因此**不傳 `--mode`**(讓 marker 取裝置預設),
`BESTOCR_MARKER_MODE` 可強制覆寫。這剛好也滿足 #15 自己導出的設計約束
——「把 layout 留在 grammar path 之外」。engine 的 tradeoff 標籤逐字寫明
這件事,而不是沿用舊結論。

## Phase 4 — document-class routing

- `DocumentClass`(`unspecified` / `single_column` / `multi_column` /
  `tabular` / `mixed`),defaulted 進 `WorkloadSpec`。
- 規則(spec §7.3):後三者要求 `assembly != .none`;前兩者**零約束**,所以
  既有選擇逐字不變(有測試釘住 with-axis == without-axis)。
- `tabular` 只要求 `!= .none` 而非 `.fullStructure`:marker 確實會產出 table
  block(只是較不可靠),用 capability filter 把它濾掉等於在**沒有 measured
  row** 的情況下做品質判斷。品質差異交給 tradeoff 標籤承擔。
- **成本要跟正確性一起印**:`AutoRouter.Selection.notice` 在 class 收窄
  roster 時說明「只剩 assembly engine,而它們比 per-page 慢得多」;
  `RunSummary.notices` 把它帶出 pipeline(CLI / MCP 各自 render,誰都不能
  靜默丟掉)。
- 找不到 assembly engine 時給**誠實的空答案**,不會拿 per-page 引擎頂替。

## Phase 5 — tradeoff 標籤

- `OCREngine.tradeoffNote` 是 **protocol requirement + extension 預設**,不是
  只放在 extension:後者透過 `any OCREngine` 會 static dispatch 到 `nil`,
  標籤會存在於型別裡卻永遠到不了使用者。有測試直接釘住這條 dispatch。
- `list-engines` 多一個 ASSEMBLY 欄 + tradeoff 行;`recommend` 的每個 entry
  帶 tradeoff(evidence-pending 也帶——新引擎大部分時間都活在那個狀態);
  run 的結尾印 assembly block 數、`model load`(明示**不**在 per-page 時間
  內)與 chosen engine 的 tradeoff。
- CLI 與 MCP 共用 `DocumentClass.parse`(接受 `multi-column` 這種人會打的
  寫法),兩個表面不會漂到接受不同字。

## 實測(live,非只有單元測試)

- `bestocr list-engines`:13 引擎,`doc.marker` **✓ available**(真的 probe
  過),`doc.paddleocr-pipeline` 誠實回報 `ModuleNotFoundError` + 安裝提示。
- `recommend --document-class multi-column` → 只剩兩個 `doc.*`,附成本說明;
  `--document-class` 不合法值會大聲失敗;無 class 時輸出與改動前相同。
- `recommend --doc-type scanned_doc --priority speed` → 既有 20 筆 T2 rows
  仍 RANKED,note 顯示 canonical `speed.ms_per_page@v1`。

## Residue(誠實記錄)

1. **`doc.paddleocr-pipeline` 沒有端到端實跑過**:這台機器上 paddleocr 不在
   任何可 import 的 python(#15 的環境已不存在)。adapter 是照 PaddleOCR 3.x
   文件 + 防禦性解析寫的(`PaddleOCRVL` → `PPStructureV3` 退階、
   `parsing_res_list` 的多種鍵名、result 物件三種形狀),`py_compile` 與
   probe 路徑有測,**但 `assemble` 的實際輸出未經真實 paddle 驗證**。
   probe-gated,所以缺席時是誠實的 unavailable + 安裝提示,不是假通過。
2. **`doc.marker` 的 `assemble` 也未實跑**(需下載模型、單頁分鐘級);probe
   實測可用,block 映射用 fixture JSON 驅動 adapter 真實程式碼測過。
   `BESTOCR_TEST_DOCPIPELINE=1` 可跑真實路徑。
3. **兩個新 estimand 依然沒有任何數字**,`recommend` 對依賴它們的問題必須
   continue 回 evidence-pending。要量就需要人工標註的參照子集,而那份子集
   必須用**可再散布**的素材建(#15 的語料不行)——這是 spec §12 的最大
   open item,不在本批次。
4. **cross-page 組裝不在能力範圍內**(iron law:引擎只看頁面影像)。跨頁
   表格、跨頁 reading order 都不解決。
