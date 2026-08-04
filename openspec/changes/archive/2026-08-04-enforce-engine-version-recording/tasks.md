## 1. 版本型別

- [x] 1.1 新增 `EngineVersion`（含 `components: [String: String]` 與 `resolution: Resolution`）與 `Resolution` 列舉（`declared` / `probed` / `adapterReported` / `unavailable`），兩者皆為 `Sendable` 與 `Codable`。完成後，空 `components` 搭配 `unavailable` 是合法值，且不需要任何表示未知的字串常數。驗證：於 `Tests/BestOCRKitTests/EngineVersionTests.swift` 新增 encode 後 decode 回原值的測試，涵蓋非空 components 與空 components 兩種情形。（對應 requirement `Version data records components and how they were obtained`；design 決策三：`EngineVersion` 只保留元件對應與取得方式兩個欄位）

## 2. Protocol 契約

- [x] 2.1 於 `Sources/BestOCRKit/CoreTypes.swift` 的 `OCREngine` 新增 `func resolveVersion() async -> EngineVersion`，且**不**在 extension 提供預設實作。完成後，未宣告該成員的型別無法通過編譯。驗證：暫時註解掉任一 engine 的該成員，執行 `swift build` 應失敗並指出缺少 protocol 成員；確認後還原。（對應 requirement `Every OCR execution point declares its version`；design 決策一：版本宣告放在 protocol，不放在各 engine 的建構處；design 決策二：不提供 protocol extension 預設實作）

## 3. 各執行點提供版本來源

- [x] 3.1 `VisionEngine` 回報作業系統版本，`resolution` 為 `declared`。完成後其結果帶有形如 `["macOS": "<版本>"]` 的 components。驗證：測試斷言該 engine 的 `resolveVersion()` 回傳 `declared` 且 components 非空。（對應 requirement `Every OCR execution point declares its version`）
- [x] 3.2 `TesseractEngine` 以執行 CLI 取得版本，`resolution` 為 `probed`；CLI 不存在或逾時時回傳空 components 與 `unavailable`，且辨識流程不中斷。驗證：測試以不存在的 CLI 路徑注入，斷言辨識仍完成且 `resolution` 為 `unavailable`。（對應 requirement `Unavailable versions are recorded, not omitted`）
- [x] 3.3 `VLMEngine` 回報模型標籤與 runtime 版本，`resolution` 依取得方式為 `declared` 或 `probed`。完成後 components 同時含模型標籤與 runtime 兩項。驗證：測試斷言 components 的鍵數不少於一，且不含空字串鍵。（對應 requirement `Every OCR execution point declares its version`）
- [x] 3.4 `CloudReferenceEngine` 在服務端未提供版本時回傳空 components 與 `unavailable`，且不由 provider 名稱、請求日期或先前觀察值推定版本。驗證：測試斷言 components 為空且 `resolution` 為 `unavailable`。（對應 requirement `Unavailable versions are recorded, not omitted`）
- [x] 3.5 `ExternalToolEngine` 改以 `EngineVersion` 承載 adapter 回報的版本，`resolution` 為 `adapterReported`，工具名稱作為 components 的鍵。完成後既有行為不變，僅資料形狀改變。驗證：既有 `Tests/BestOCRKitTests/ExternalToolEngineTests.swift` 全數通過，並新增一則斷言 `resolution` 為 `adapterReported`。（對應 requirement `Version data records components and how they were obtained`）
- [x] 3.6 `DocumentPipelineEngine` 同 3.5 改以 `EngineVersion` 承載 adapter 回報的版本。驗證：既有 `Tests/BestOCRKitTests/DocumentPipelineEngineTests.swift` 全數通過，並新增一則 `resolution` 斷言。（對應 requirement `Version data records components and how they were obtained`）

## 4. 建構路徑收斂

- [x] 4.1 使 `Sources/BestOCRKit/OCRModels.swift` 的 `ConditionTuple` 建構在寫入路徑上必須帶入 `EngineVersion`，欄位型別維持 optional 以保既有結果檔可解碼。完成後，新產出的結果不可能缺版本。驗證：對六個 engine 各跑一次辨識，斷言其結果的版本欄位皆非 nil。（對應 requirement `All construction paths carry version data`；design 決策四：讀寫方向採用不同嚴格度）
- [x] 4.2 `Sources/BestOCRKit/RunLog.swift` 的條件資訊建構同樣帶入版本。完成後該路徑產出的記錄與 engine 產出的記錄在版本欄位上一致。驗證：測試斷言經由該路徑產出的記錄版本欄位非 nil。（對應 requirement `All construction paths carry version data`）

## 5. 向後相容

- [x] 5.1 確認既有已歸檔結果檔仍可解碼，其版本欄位為 nil 且不被事後推定。驗證：以一份不含版本欄位的結果檔 JSON 作為測試資料進行 decode，斷言成功且版本為 nil。（對應 requirement `Existing archived results remain decodable`；design 決策四：讀寫方向採用不同嚴格度）

## 6. 覆蓋率驗收

- [x] 6.1 新增一則涵蓋全部 engine 的測試，逐一斷言 `resolveVersion()` 回傳的 `resolution` 屬四個合法值之一，且當 `resolution` 非 `unavailable` 時 components 非空。完成後「有 engine 忘記填版本」無法在不被測試發現的情況下存在。驗證：該測試在任一 engine 回傳空 components 搭配非 `unavailable` 時失敗。（對應 requirement `Every OCR execution point declares its version`；requirement `Unavailable versions are recorded, not omitted`）
