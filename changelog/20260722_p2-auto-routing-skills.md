# 2026-07-22 — P1+P2:repo 公開、發佈鏈焊死、auto-routing 預設化、workflow skills

## P1 — 發佈鏈最後一哩(當日稍早)

- **repo 公開**(原 private 是 plugin 匿名下載 404 的根因)+ security
  baseline 全綠:secret scanning、push protection、dependabot alerts +
  security updates、main branch protection(no force-push / no delete /
  linear history)。audit:`macdoc/scripts/audit-security.sh bestOCR` → OK。
- **wrapper 修復**:先試決定性 release URL(`releases/download/v<ver>/<name>`),
  API 探索降為 fallback — 匿名 API rate limit(NAT/CI 共用 IP 常見)不再
  擋安裝。端到端實測:自動下載 v0.3.0 → sidecar → notarized 簽章驗證 →
  MCP 握手 6 tools 全通。
- **plugin 真實安裝**:`claude plugin marketplace add PsychQuant/bestOCR`
  + `claude plugin install bestocr@bestocr`(user scope)成功。

## P2 — auto-routing + fallback + skills(v0.4.0)

- **AutoRouter**:候選順序 = Recommender 的回答(tier 紀律原封不動;
  ranked 在前、unverified 在後、cloud 永不出現)。
- **executeAuto + fallback chain**(spec §8):依序嘗試候選,跳過
  unavailable、吞下失敗繼續,**每一跳都記錄在 `RunSummary.attempts` 並
  印出**(`↷ X skipped: ...`);全滅則大聲列出全部嘗試。顯式 `--engine`
  維持不 fallback(使用者指定優先)。
- **auto 成為預設**:CLI `bestocr run <file>`(不給 --engine)與 MCP `ocr`
  tool(engine 參數改 optional)都走 auto;新增 `--priority` / `--math`。
- **workflow skills**(bestASR 四件套補齊):`/bestocr:ocr`(任意 PDF/圖 →
  Markdown,auto 路由)、`/bestocr:compare`(文件離機需先徵得同意)、
  `/bestocr:evidence-ingest`(人工品管閘門,含閉環驗證步驟)。
- plugin/marketplace/semver bump 0.4.0;release v0.4.0(notarized)。

## 驗證

- `swift test`:89 tests / 20 suites 全過(P2 新增 7)。
- auto 真實 smoke:`run <截圖> --priority speed`(無 --engine)→ 依先前
  ingest 的 T2 speed row 選中 vision — measured routing 實際生效。
- MCP auto 測試:`ocr` 不帶 engine 經 stub registry 自動路由成功。
