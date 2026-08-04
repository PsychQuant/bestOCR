## Why

`ConditionTuple.toolVersion` 由 #28 加入，但只有兩個 adapter-backed engine 會填；其餘四個執行點（Vision／Tesseract／VLM／Cloud）產出的 row 版本為 nil。缺版本是靜默的——編譯器不提醒、測試不失敗，於是「哪一版讀出來的」在多數 row 上無法回答，跨工具升級的結果也無從比較。

## What Changes

- 為 `OCREngine` 新增版本宣告要求 `resolveVersion() async -> EngineVersion`，**刻意不提供 protocol extension 預設值**，使未宣告版本的 engine 無法通過編譯。**BREAKING**：現有 6 個 engine 實作與測試 mock 皆需補上該成員。
- 新增 `EngineVersion` 型別，含 `components: [String: String]`（元件名稱到版本的對應）與 `resolution`（版本的取得方式：`declared` / `probed` / `adapterReported` / `unavailable`）。
- 四個目前未填版本的執行點各自提供版本來源：Vision 取作業系統版本、Tesseract 探測 CLI 版本、VLM 取模型標籤與 runtime、Cloud 於無法取得時回報空 components 並標記 `unavailable`。
- 收斂 `ConditionTuple` 的建構路徑，使版本資訊必然隨每筆結果寫出。目前有七個建構點：六個 engine 加上 RunLog 模組。
- `ConditionTuple.toolVersion` 維持 optional，僅為讓既有 `*.meta.json` 繼續解碼；強制點放在 protocol 與建構路徑，不放在欄位型別。

## Capabilities

### New Capabilities

- `engine-version-provenance`: 每個 OCR 執行點都必須宣告其引擎版本與該版本的取得方式，並使版本資訊隨每筆結果寫出。

### Modified Capabilities

(none)

## Impact

- Affected specs: `engine-version-provenance`
- Affected code:
  - New:
    - `Sources/BestOCRKit/EngineVersion.swift`
    - `Tests/BestOCRKitTests/EngineVersionTests.swift`
  - Modified:
    - `Sources/BestOCRKit/CoreTypes.swift`
    - `Sources/BestOCRKit/OCRModels.swift`
    - `Sources/BestOCRKit/RunLog.swift`
    - `Sources/BestOCRKit/Engines/VisionEngine.swift`
    - `Sources/BestOCRKit/Engines/TesseractEngine.swift`
    - `Sources/BestOCRKit/Engines/VLMEngine.swift`
    - `Sources/BestOCRKit/Engines/CloudReferenceEngine.swift`
    - `Sources/BestOCRKit/Engines/ExternalToolEngine.swift`
    - `Sources/BestOCRKit/Engines/DocumentPipelineEngine.swift`
  - Removed: (none)
- 相依與系統：不新增外部相依。Tesseract 路徑會多一次 CLI 探測；Cloud 路徑在無法取得版本時不發額外請求。既有已歸檔的結果檔維持可解碼，其版本欄位仍為 nil，屬永久未知而非可事後推定。
