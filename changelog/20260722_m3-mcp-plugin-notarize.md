# 2026-07-22 — M3:MCP server、Claude plugin、notarize pipeline

## 摘要

spec 里程碑 M3 落地:`bestocr-mcp` MCP server(6 tools、async jobs)、
Claude plugin marketplace(本 repo 兼作 marketplace)、sign+notarize
release pipeline。計畫:
`docs/superpowers/plans/2026-07-22-bestocr-m3-mcp-plugin-notarize.md`。

## 內容

- **BestOCRMCPCore**:`SingleFlight` 與 `JobRegistry` 自 bestASR 逐字 port
  (engine-independent by design;copy 不 import)。`BestOCRMCPServer` actor:
  6 tools(`ocr`/`recommend`/`list_engines`/`list_models`/`ocr_status`/
  `ocr_result`),dispatch 錯誤一律變 loud `isError` 結果,server loop 不死。
- **併發紀律**(bestASR #80/#86):重 OCR 走 single-flight gate(參數解析在
  gate 外,壞呼叫 fail fast);`ocr_result` long-poll cap 25s;完成 job
  300s 後 evict(in-memory only,v1 限制照文件)。
- **Warm 說法誠實化**:bestOCR 的 VLM 暖機住在 Ollama server(keep_alive),
  不在本 process — MCP 的貢獻是常駐 probe + 防打爆的 gate,tool 描述照實寫。
- **單一 binary 發佈**:adapter scripts 從 SPM `Bundle.module` resources 改為
  內嵌字串常數(`AdapterScripts.swift`,由 .py 機械生成),執行時 materialize
  到 `~/.bestocr/adapters/`(`BESTOCR_ADAPTER_DIR` 可覆寫),內容不符自動重寫。
  否則 notarized binary 下載後 ext.* 引擎會全滅。
- **Plugin**:`.claude-plugin/marketplace.json` + `plugins/bestocr/`
  (plugin.json 0.3.0、`.mcp.json`、auto-download wrapper —— bestASR 模式:
  版本 sidecar、pinned tag → latest fallback、atomic swap、quarantine strip)。
- **Release pipeline**:`Makefile` `release-signed`(Developer ID sign
  `--options runtime --timestamp` → notarytool submit --wait → sha256
  sidecars);GitHub release `v0.3.0` 附 `bestocr-mcp`/`bestocr` + sha256。

## 驗證

- `swift test`:67+ tests 全過(新增 JobRegistry/SingleFlight/Server 13 tests、
  adapter materialization test)。
- stdio 協定 smoke:initialize → serverInfo 0.3.0;tools/list → 6 tools;
  tools/call list_models → 渲染正確。
- wrapper `bash -n`、三個 plugin JSON `json.tool` 驗證。
- notarize:`che-mcps-notary` profile 驗證存活後 `make release-signed`,
  Apple 回 Accepted;`gh release create v0.3.0` 上傳 binaries + sha256。
