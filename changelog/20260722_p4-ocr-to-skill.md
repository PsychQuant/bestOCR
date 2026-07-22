# 2026-07-22 — P4:/bestocr:ocr-to workflow skill(OCR → docx via macdoc)

Issue #1(feature)。純 plugin 層,零 Swift code 變更。

## 內容

- **新 skill `/bestocr:ocr-to`**:輸入 PDF/影像 → OCR(auto-routing 照舊,
  MCP `ocr` tool 優先、CLI fallback)→ `macdoc convert --to docx` → docx。
  v1 docx-only(#1 Clarity 拍板);math 純文字直通(LaTeX 字面保留,OMath
  升級見 #3);macdoc 缺席 probe fail-fast + 安裝提示。
- **版本策略**:plugin/marketplace 0.6.0(plugin-shell-only);binary semver
  留 0.5.1——wrapper 對缺 tag 版本 fallback releases/latest(已讀 wrapper
  邏輯確認)。
- **6-AI verify 後強化**(in-scope fixes):MCP 參數名修正(`out_dir`/`pages`)、
  workdir 防覆寫規則(獨立輸出目錄、no-clobber、同 stem 批次防自我覆寫)、
  MCP「存在但不可用」的 fallback 邊界、路徑安全指引($()/反引號等)、
  docx 有效性檢查、math 問題 md-first 歸因、cloud 排除保證引用(spec §6.1.3)。

## 驗證

- 6-AI verify(4 lens sonnet + DA + Codex gpt-5.6-sol):0 CRITICAL,
  HIGH/MEDIUM 全數 in-scope 修正或分拆 follow-up。
- 驗收實跑:公式密集測試文件 2 頁 → docx,6/6 公式字面保留(含 XML escape
  往返);第二樣本內容往返正常;swift test 111/111。
