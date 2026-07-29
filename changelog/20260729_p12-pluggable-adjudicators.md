# 2026-07-29 — P12:pluggable consensus adjudicators(#17,PR #32)

由並行 session 實作(spec 先以 PR #22 進 main),本 session 負責 merge 與
close;此記錄自其 PR/commits 忠實摘要。**304 tests / 46 suites**(合併後
main;= 該 branch 291/44 + #28/#29 的 13/2,三條 lane 乾淨組合)。

## 核心:seam 不是重點,回傳型別才是

`ConsensusPipeline` 呼叫 estimator 只有一行;真正的 blocker 是
`ConsensusEstimate` 是 **Dawid-Skene 形狀的回傳型別**,別的模型無法誠實地
從它報告。`AdjudicatorDiagnostics` 承載關鍵區分:**`nil` = 這個模型沒有這個
概念;`[:]` = 有概念但無可報** —— 沒有這個區分,naive-majority 的報告會被
讀成退化的 Dawid-Skene。兩個方向都有測試釘住。

## 六個 adjudicator(`--adjudicator`;`--list-adjudicators` 印 tradeoffs 絕不排名)

| id | 加了什麼 | 做不到什麼 |
|---|---|---|
| `ds-lite` | 預設;within-item agreement 學 competence | 看不見「怎麼錯」;共謀對支配它 |
| `majority` | **control** —— 無 competence 無假設 | 沒有;那正是它的用途 |
| `ds-full` | 每引擎**字元級方向性 confusion** | `rn`→`m`(2:1)不可表示;unigram |
| `prior-weighted` | competence 先驗來自**實測** T2 `word_recall` rows | 只有 benchmark 好它才好;未測引擎取中性 0.5(揭露) |
| `irt` | per-item difficulty + per-engine ability 聯合估計 | 小 rater panel 上的 ridge 點估計;無 2PL/3PL |
| `rover` | **插入/刪除**可表示(confusion network,顯式 ε) | 字內錯誤最粗 |

## 三個改變設計的發現(出自實作,回饋 spec)

1. **教科書 full DS 對 OCR 行不可行**:沒有跨 item 共享的 category set →
   confusion 降到**字元層**(錯誤本來就住在那);代價誠實揭露 —— spec 用
   `rn`→`m` 當動機例,unigram 分解成 `r`→`m` + `n`→ε,承諾只兌現一半,
   型別內寫明。
2. **closed-set 擴充成本比 spec 預測早一個 phase 到來**(phase 3 的
   competence prior 就是新種類的量)—— 記錄而非默默修補,作為重審 closed
   set 的證據。
3. **ROVER 給了 phase 0b 最尖銳的理由**:它的 item 是 token slot 不是行,
   `low_consensus_share` 數的是 token —— 同一個詞、不同的量,正是 estimand
   名要帶 adjudicator id 的原因。`consensus.<id>.<quantity>@v1`;legacy 無
   資格名讀作 ds-lite(歷史事實,非假設)。

## 刻意不建:Bayesian CCT / GCM

需要 sampler 與真後驗;掛著那個名字出點估計,就是本 issue 要防止的那種
mislabelling。IRT 以「顯式 ridge-penalized 點估計」之名出貨,Rasch
identifiability anchor 有測試釘住。

## Fixture 紀律(三次修正同一根因,已寫進測試)

共識 fixture 裡**每一個錯誤都必須被攜帶真值的雙引擎聯盟投票壓過** ——
否則字典序 tie-break 會把錯字選成真值並獎勵產生它的引擎。

## 本檔案外的收尾(close session)

README(consensus 段)與 CLAUDE.md(架構、測試數、P12)同步;#17 squash
本身零文件(18 檔全 code),此為 close 時 doc-sync sweep 的產出。
