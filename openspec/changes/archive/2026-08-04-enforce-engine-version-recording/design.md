## Context

`ConditionTuple.toolVersion` 是 #28 為 adapter-backed engine 加入的欄位，其註解已載明動機：同名工具的不同世代（例如 surya 0.17.x 與 0.22.x）是不同系統，缺少版本欄位時兩者的 row 無法區分。

但 #28 的範圍限於 adapter-backed engine。現況是六個 engine 中只有 `ExternalToolEngine` 與 `DocumentPipelineEngine` 會填版本，其餘四個（Vision／Tesseract／VLM／Cloud）一律為 nil。這四個恰好涵蓋作業系統框架、外部 CLI、本地模型與雲端服務——都是會隨系統或後端更新而改變行為，卻不會通知呼叫端的路徑。

三項結構性成因：

1. `ConditionTuple.toolVersion` 宣告為 optional 且初始化參數帶預設 nil，使「不填」成為零成本路徑。新增 engine 時預設即為 nil，編譯器不提醒、測試不失敗。
2. `OCREngine` protocol 承載 `id`、`family`、`capabilities`、`tradeoffNote`、`probe()`、`recognize()`，但沒有任何成員承載版本，於是各 engine 各自決定填或不填。
3. 已填的兩個依賴 adapter 回傳的版本字串。該字串是否取自實際執行的直譯器，bestOCR 無從驗證。

約束：既有已歸檔的結果檔必須維持可解碼，這是 `toolVersion` 當初設為 optional 的原因。

## Goals / Non-Goals

**Goals:**

- 使每個 OCR 執行點都必須宣告版本，且未宣告時無法通過編譯
- 使版本的取得方式成為資料的一部分，讓下游能判斷可信度差異
- 既有已歸檔結果檔維持可解碼

**Non-Goals:**

- 不保證 adapter 回報的版本必然正確。bestOCR 能要求宣告取得方式、能讓錯誤可追查，但無法驗證 adapter 內部查的是否為實際執行的直譯器。
- 不回溯補填既有結果檔。版本欄位為 nil 的既有 row 屬永久未知，不做事後推定。
- 不為雲端服務推定版本號。後端模型可能靜默更新，填入看似精確的版本比標記為無法取得更具誤導性。
- 不引入外部相依，不改變任何 engine 的辨識行為。

## Decisions

### 決策一：版本宣告放在 protocol，不放在各 engine 的建構處

`ConditionTuple` 目前有七個建構點：六個 engine 加上 RunLog 模組。若在建構處逐一補填，等於七處各自維護同一條規則，且新增 engine 時仍會遺漏——那正是現況。

改為在 `OCREngine` 增加成員 `resolveVersion() async -> EngineVersion`。宣告成 `async` 是因為部分來源需要 I/O：Tesseract 需執行 CLI 查版本，雲端需查詢服務端。

替代方案：在 `ConditionTuple` 的建構函式改為必填參數。此法能強制七個建構點，但把「版本從哪來」的知識散落在建構處而非 engine 自身，且 RunLog 模組並不知道 engine 的版本來源。

### 決策二：不提供 protocol extension 預設實作

`tradeoffNote` 目前以 extension 提供 nil 預設，其後果正是 `toolVersion` 今天的處境：沒宣告等於靜默的空值。若對 `resolveVersion()` 比照辦理，遺漏會再次變成無聲的，本次改動將重演 #28「修好實例、類別仍在」的循環。

代價是這成為 breaking change：六個 engine 實作與測試中的替身皆需補上該成員。此代價是編譯期的、範圍已知（實作全在本 repo 內），且被發現的時機正是我們要的——相對於執行期靜默產出無版本的 row。

### 決策三：`EngineVersion` 只保留元件對應與取得方式兩個欄位

```
public struct EngineVersion: Sendable, Codable {
    public let components: [String: String]
    public let resolution: Resolution
}

public enum Resolution: String, Sendable, Codable {
    case declared          // engine 內宣告，例如綁定作業系統版本
    case probed            // 執行期探測，例如查詢 CLI 版本
    case adapterReported   // adapter 回報，bestOCR 無法驗證
    case unavailable       // 無法取得
}
```

曾考慮額外設一個「主要版本」欄位供顯示使用，但該欄位的值必然重複 `components` 中的某一項，且「哪一項算主要」是消費端的判斷——關心 surya 版本與關心 torch 版本的分析會有不同答案。把該判斷固化在生產端是過早決定，故不設此欄位。

`resolution` 承載的是不同維度的資訊，不與 `components` 重複。它讓「adapter 自報無法驗證」這件事從文件註腳變成可查詢的資料：下游判斷兩筆讀值是否可視為獨立來源時，`probed` 與 `adapterReported` 的可信度本就不同。

無法取得版本時，`components` 為空對應且 `resolution` 為 `unavailable`。空對應天然表達「沒有版本資訊」，因此不需要另訂一個表示未知的字串常數。

### 決策四：讀寫方向採用不同嚴格度

`ConditionTuple.toolVersion` 維持 optional。這不是妥協，而是因為讀與寫的需求方向相反：讀取需寬鬆以解碼既有結果檔，寫入需嚴格以確保新結果帶版本。強制點放在 protocol 與建構路徑，而非欄位型別，即可同時滿足兩者。

替代方案：將欄位改為必填。此法會使既有已歸檔結果檔無法解碼，違反 #28 建立此欄位時的相容性前提。

## Implementation Contract

**Behavior**：任一 engine 完成辨識後，其產出的結果所攜帶的條件資訊必然包含版本與該版本的取得方式。無法取得版本的情形下，結果仍帶有版本資訊，其元件對應為空且取得方式標記為無法取得——不存在「沒有版本欄位」的結果。

**Interface / data shape**：

- `OCREngine` 新增成員 `func resolveVersion() async -> EngineVersion`，無 extension 預設實作
- `EngineVersion` 為新增型別，含 `components: [String: String]` 與 `resolution: Resolution`
- `Resolution` 為新增列舉，四個 case 依序為 `declared`、`probed`、`adapterReported`、`unavailable`
- `ConditionTuple.toolVersion` 型別不變，維持 optional 以保既有結果檔可解碼

**Failure modes**：

- 版本探測失敗（CLI 不存在、逾時、服務端無回應）不使辨識失敗。該情形回傳空 `components` 與 `unavailable`，辨識照常進行。
- Adapter 回報的版本字串不做正確性驗證，僅標記為 `adapterReported`。這是刻意不處理的部分，理由見 Non-Goals。
- 未宣告 `resolveVersion()` 的 engine 無法通過編譯。這是刻意讓其顯性失敗，而非以預設值吸收。

**Acceptance criteria**：

- 對六個 engine 各自呼叫辨識流程，其結果的條件資訊中版本欄位皆非 nil
- 新增一個未實作 `resolveVersion()` 的 engine 型別時，編譯失敗
- 以既有已歸檔的結果檔進行解碼，仍能成功，且其版本欄位為 nil
- Tesseract 路徑在 CLI 不存在時，辨識仍完成，且取得方式標記為無法取得
- RunLog 模組產出的條件資訊同樣帶版本，不因不在 engine 目錄下而遺漏
