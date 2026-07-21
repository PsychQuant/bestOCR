# 2026-07-22 — M4:cloud reference、compare、evidence ingest(spec 四里程碑完結)

## 摘要

spec 最後一個里程碑落地:cloud reference 引擎(Claude/OpenAI/Gemini)、
`bestocr compare`、`bestocr evidence ingest`。**證據迴圈以真實資料閉合**:
run(vision 實測 15.8s)→ ingest(T2 row + runlog 溯源)→ recommend 回
RANKED (T2) 並引用該 row。計畫:
`docs/superpowers/plans/2026-07-22-bestocr-m4-cloud-compare-ingest.md`。

## 內容

- **CloudProvider / CloudReferenceEngine**(11 引擎 roster):raw HTTPS
  (Swift 無官方 Anthropic SDK,按 claude-api skill 指引走 cURL shape)。
  請求建構與回應解析是純函數,以 canned JSON 單元測試,不打網路。
  - Claude:`x-api-key` + `anthropic-version: 2023-06-01`、image block 在
    text 前、預設 `claude-opus-4-8`(skill 指定)、`stop_reason: refusal`
    顯式處理。OpenAI:chat/completions + data-URI。Gemini:generateContent
    + inline_data。模型預設皆 env 可覆寫(`BESTOCR_*_MODEL`)。
  - probe = API key env 存在與否;hint 明示「documents leave the machine」。
  - **排名隔離有測試釘住**:cloud 引擎即使有匹配 evidence rows 也絕不出現在
    recommend entries(spec §6.1.3)。
- **Comparator + `compare`**:`quality.token_recall_vs_cloud@v1` —— 具名
  版本化公式(schema 硬規則 2):NFC 正規化、非字母數字切分、multiset
  recall。輸出明示「cloud 是參照不是 ground truth,不可與 word_recall 混用」。
  正規化一次、兩引擎吃同一組頁面影像。
- **EvidenceIngest + `evidence ingest`**:顯式閘門(spec §6.2)——
  runlog entry → `speed.ms_per_page` T2 row(mean ms/page),source
  `runlog:<id>`,非 nominal thermal 頁面自動成 caveat(硬規則 5)。
  id 支援唯一前綴;缺失/歧義大聲報錯。M4 限 speed estimand(quality 需
  runlog 沒有的參照,文件明載)。

## 驗證

- `swift test`:85 tests / 21 suites 全過(M4 新增 18)。
- 全迴圈 E2E:`run → evidence ingest → recommend` 實測回 RANKED (T2),
  引用真實 runlog id;8 個無 row 引擎誠實標 unverified;cloud 不在列。
- `list-engines`:11 列;cloud 三列 `✗ <KEY> not set` + export hint。
- TDD 途中抓到一個實作 bug:normalize 用 whitespace 切分會把 em-dash 黏字
  (`world—42` → `world42`),按測試定義的行為修為非字母數字切分。

## 同日稍早(M3,見 20260722_m3 changelog)

v0.3.0 release 已發佈(notarized `bestocr-mcp` + `bestocr` + sha256),
plugin marketplace 就緒:`claude plugin marketplace add PsychQuant/bestOCR`。
