# 2026-07-28 — P9:`bestocr pipeline`(#24)

一個指令從輸入走到交付檔案:normalize → route → OCR → assemble → convert,
每個階段都印出來。**核心不是「把指令串起來」,而是把 `ocr-to` skill 裡那些
用血換來的規則從散文變成 code。**

## 為什麼要做:散文不是強制力

`plugins/bestocr/skills/ocr-to/SKILL.md` 有 83 行指示,其中幾條之所以存在,是
因為它們曾經出過事(#1 / #3 / #7)。問題是那些規則只是**寫給 agent 讀的字**:
跳過第 3 步就會覆寫使用者手工做的 `.docx`,而**什麼都不會失敗**。

現在它們是有測試釘住的行為:

| 規則 | 之前 | 現在 |
|------|------|------|
| 不寫進輸入資料夾 | SKILL.md 第 3 步 | 預設輸出 `<input 同層>/bestocr-out/`;`OutputPlanner.defaultOutDir` |
| 不覆寫既有檔 | 「先問使用者」 | **跑 OCR 之前**就檢查整批,列出檔名拒絕;`--overwrite` 才過 |
| 批次同名不互相蓋 | 「加來源後綴」 | 對稱加資料夾後綴(只改一邊就看不出誰來自哪)+ 會終止的 fallback |
| math → pandoc | 「以 pandoc 可辨識的 math node 為準」 | `MarkdownMath` 實作 **pandoc 自己的規則** |
| 產出要驗 | 「docx 是可開啟的 ZIP 且含 `word/document.xml`」 | `DocxValidator` 直接驗 magic bytes + part 名 |
| 轉檔器歸因 | 「依實際轉檔器歸因」 | `Outcome.attribution` 進報告,`--converter` 強制時無 fallback(否則歸因會變謊) |

## math 判定用 pandoc 的規則(兩個方向都會痛)

開頭 `$` 右邊必須是非空白,結尾 `$` 左邊必須是非空白**且後面不是數字**。這一條
規則就讓 `$5 and $10` 正確地是貨幣而不是公式——結尾候選 `$` 左邊是空白,不成立。
另外排除 fenced code(`echo "$HOME/$USER"` 完美符合 inline math 規則,不排除就
會誤判)、inline code span、以及 `\$`。

判錯的兩個方向成本都是實的:false negative 把公式當文字送去 macdoc 變字面
LaTeX;false positive 把價目表送進 math-aware 路徑。

## 誠實面的三個設計決定

1. **拒絕發生在花錢之前**。整批的輸出衝突在任何 OCR 之前檢查完,所以拒絕的代價
   是秒級而不是「跑了十分鐘才發現不能寫」。
2. **exit 0 不算證據**。轉檔器可以 exit 0 卻產出一個不是 Word 文件的 ZIP;
   `DocxValidator` 直接看 `PK\x03\x04` + `word/document.xml`(ZIP 的 entry 名
   不壓縮,所以 byte search 是結構上正確的檢查,不用解壓)。
3. **轉檔失敗不丟掉 OCR**。markdown 是昂貴的產物,轉檔掛掉時它留在磁碟上、
   失敗原因與 converter hops 一起記進報告(跟 engine fallback 一樣「不靜默」)。
   批次中單檔失敗記錄後繼續,最後逐檔彙報;**有任何失敗時 CLI exit 非 0**,
   partial batch 不會對 script 回報成功。

## 順帶的最小改動

- `RunPipeline.execute` / `.executeAuto` 加 `outputStem:`(defaulted):pipeline
  需要用**去重後**的檔名寫產物,否則批次同名 stem 會在 md 這一層就先撞掉。

## 與 marker 的關係(#24 issue body 已記,這裡只留結論)

marker 本身就是 PDF → markdown 的 pipeline,所以「自己做 pipeline」聽起來像重造
它——不是。marker 是這條 pipeline 裡的**一個階段選項**(`doc.marker`,#16 納入),
它到 markdown 就停,不做路由也不標 evidence。執行期衝突是**讀原始碼確認**過的:
`surya/inference/backends/spawn.py` 用 `find_free_port()` 動態取 port + `atexit`
清理,所以它的 `llama-server` 不會撞 Ollama 的 11434 或手動起的 server。真正存在
的是耦合而非衝突:surya 從 `PATH` 拿 `llama-server`(`settings.LLAMA_CPP_BINARY`),
brew 升版會同時動到 marker;而它與 Ollama 都要 Metal——bestOCR 內部已用
single-flight 序列化重型 OCR。

## 實測

- 真 PDF → `pipeline --engine vision --to docx`:產出 `.docx`(結構驗證通過)、
  `.md`、`.meta.json` + runlog id(可直接 `evidence ingest`);converter 正確
  選到 macdoc(該份 md 無 math)並附字面-LaTeX 限制聲明。
- 同一指令再跑一次 → **在 OCR 之前**逐名拒絕(`smoke.md, smoke.docx`),
  既有檔 mtime 未變。
- 單元測試含真實轉檔:pandoc 與 macdoc 各自產出的 docx 都通過驗證;批次同名
  stem 產出兩份;單檔失敗不中止批次;轉檔失敗保留 markdown。

## 踩到的坑:平行測試被端到端 suite 卡死(值得記住)

加完 `PipelineFlowTests` 後,`swift test` **平行跑會整個卡住** —— 263 個測試
「started」、只有 39 個完成,連純字串函式的測試都沒回來。`--no-parallel` 則
17 秒全綠。

- **先猜錯的方向**:測試裡用了 `setenv`/`unsetenv`(Darwin 的環境變數突變與其他
  測試併發的 `getenv` 不安全,而這個 suite 幾乎每條路徑都在讀 env)。改成注入
  `locateConverter` 之後仍然卡 —— 所以那不是根因(但注入本身是對的,保留)。
- **真正的根因**:`PipelineFlowTests` 每個測試都要經 AppKit/CoreGraphics 渲染
  PDF fixture、跑 Vision、再 spawn 轉檔器。把這種東西 fan out 到平行 runner
  會讓整個 process 卡住(CG/Vision 在多執行緒同時初始化)。
- **修法**:`@Suite(.serialized)`。端到端 suite 本來就不該買併發 —— 它的價值是
  「真的跑一遍」,不是快。之後 8.3 秒 254 tests 全綠。
- **教訓**:`swift test` 卡住時,先跑 `--no-parallel` 分辨「測試錯」與「併發錯」,
  再看哪個新 suite 在做 framework 級的重初始化。

## Residue

1. **v1 只支援 docx**(承 #1 的 scoping)。其他 macdoc 支援的格式未納入。
2. **沒有 MCP `pipeline` tool**:agent 端目前仍走 `ocr-to` skill 或直接呼叫 CLI。
3. **`ocr-to` skill 尚未改成薄殼委派**給這個指令 —— 這是本 issue 刻意排除的
   follow-up(改 skill 要 plugin 版本 bump + marketplace 同步)。在它完成之前,
   **skill 的散文與 binary 的行為是兩份實作**,有漂移風險。
