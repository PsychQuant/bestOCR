# bestOCR M3 — MCP Server + Plugin + Notarize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship spec milestone M3: `bestocr-mcp` MCP server (6 tools, async jobs), Claude plugin marketplace in this repo, and the sign+notarize release pipeline — at bestASR parity.

**Architecture:** `BestOCRMCPCore` library (Server actor + ported SingleFlight/JobRegistry) + thin `bestocr-mcp` executable. Adapter scripts move from SPM `Bundle.module` resources to embedded string constants materialized to `~/.bestocr/adapters/` (single-binary distribution). Plugin = marketplace.json + plugin.json + .mcp.json + auto-download wrapper (bestASR pattern). Release = Makefile `release-signed` using the documented `che-mcps-notary` keychain profile.

**Tech Stack:** As M2, plus `modelcontextprotocol/swift-sdk` `.upToNextMinor(from: "0.12.0")` (same family as bestASR/che-mcps).

## Global Constraints

- All M1/M2 global constraints hold. Verification chains use `set -o pipefail`.
- MCP discipline (bestASR #80): stdout is JSON-RPC only, diagnostics to stderr; every dispatch failure becomes a loud `isError` tool result — the server loop never dies on a bad call; heavy OCR serializes through SingleFlight, read-only tools stay concurrent.
- Async-job discipline (bestASR #86): `ocr_result` long-poll cap 25 s (below client timeouts); completed jobs evicted after 300 s retention; in-memory only (documented v1 limitation).
- Distribution: the released `bestocr-mcp` is ONE arm64 binary — nothing may depend on `Bundle.module` at runtime after Task 4.
- Ports from bestASR (`Sources/BestASRMCPCore/`): `SingleFlight.swift` verbatim; `JobRegistry.swift` verbatim (both are engine-independent by design — only the doc comments' issue refs stay as-is). Same-org code; copying, not importing.
- Notarize secrets discipline (global CLAUDE.md): `DEVELOPER_ID` = `F2523DCF6D02BE99B67C7D27F633119292DA4934`, `NOTARY_PROFILE` = `che-mcps-notary` — reference handles only, no passwords anywhere.

---

### Task 1: MCP scaffold — Package target + SingleFlight/JobRegistry ports

**Files:**
- Modify: `Package.swift` (add MCP dep; `BestOCRMCPCore` library target; `bestocr-mcp` executable target)
- Create: `Sources/BestOCRMCPCore/SingleFlight.swift` (port verbatim from `/Users/che/Developer/bestASR/Sources/BestASRMCPCore/SingleFlight.swift`)
- Create: `Sources/BestOCRMCPCore/JobRegistry.swift` (port verbatim from `/Users/che/Developer/bestASR/Sources/BestASRMCPCore/JobRegistry.swift`)
- Test: `Tests/BestOCRMCPCoreTests/JobRegistryTests.swift`, `Tests/BestOCRMCPCoreTests/SingleFlightTests.swift`

**Interfaces:**
- Produces: `SingleFlight` actor (`run<T>(_:) async throws -> T`), `JobRegistry` actor (`start(_:) -> String`, `status(_:) -> State?`, `awaitResult(_:cap:) async -> Outcome`, `count`), `JobError(String)`.

Package.swift additions:

```swift
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            .upToNextMinor(from: "0.12.0")),
```

```swift
        .target(
            name: "BestOCRMCPCore",
            dependencies: [
                "BestOCRKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(name: "bestocr-mcp", dependencies: ["BestOCRMCPCore"]),
        .testTarget(name: "BestOCRMCPCoreTests", dependencies: ["BestOCRMCPCore"]),
```

Tests (RED first):

```swift
// JobRegistryTests.swift
import Foundation
import Testing
@testable import BestOCRMCPCore

struct JobRegistryTests {
    @Test func lifecycleRunningToDone() async throws {
        let registry = JobRegistry()
        let id = await registry.start { "RESULT" }
        let outcome = await registry.awaitResult(id, cap: .seconds(5))
        #expect(outcome == .result("RESULT"))
        #expect(await registry.status(id) == .done)
    }

    @Test func failureCarriesTypedMessage() async {
        let registry = JobRegistry()
        let id = await registry.start { throw JobError("engine exploded") }
        let outcome = await registry.awaitResult(id, cap: .seconds(5))
        #expect(outcome == .failed("engine exploded"))
    }

    @Test func unknownJobIsUnknown() async {
        let registry = JobRegistry()
        #expect(await registry.awaitResult("nope", cap: .milliseconds(50)) == .unknown)
        #expect(await registry.status("nope") == nil)
    }

    @Test func evictionBoundsRegistry() async throws {
        let clock = TestClock()
        let registry = JobRegistry(retention: 300, now: { clock.now() })
        let id = await registry.start { "x" }
        _ = await registry.awaitResult(id, cap: .seconds(5))
        clock.advance(by: 301)
        _ = await registry.start { "y" }     // sweep runs on start
        #expect(await registry.count == 1)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var base = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return base }
    func advance(by seconds: TimeInterval) { lock.lock(); base += seconds; lock.unlock() }
}
```

```swift
// SingleFlightTests.swift
import Testing
@testable import BestOCRMCPCore

struct SingleFlightTests {
    @Test func serializesConcurrentWork() async throws {
        let gate = SingleFlight()
        let recorder = Recorder()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    _ = try? await gate.run {
                        await recorder.enter(i)
                        try await Task.sleep(for: .milliseconds(20))
                        await recorder.exit(i)
                        return i
                    }
                }
            }
        }
        #expect(await recorder.maxConcurrent == 1)
    }
}

actor Recorder {
    var active = 0
    var maxConcurrent = 0
    func enter(_ i: Int) { active += 1; maxConcurrent = max(maxConcurrent, active) }
    func exit(_ i: Int) { active -= 1 }
}
```

Steps: write tests → `swift test --filter BestOCRMCPCoreTests` RED (module missing) → add Package targets + port the two files (copy content verbatim; no renames needed — they are engine-independent) → GREEN → commit `feat: BestOCRMCPCore scaffold — SingleFlight + JobRegistry ports (bestASR pattern)`.

---

### Task 2: BestOCRMCPServer — 6 tools + dispatch

**Files:**
- Create: `Sources/BestOCRMCPCore/Server.swift`
- Test: `Tests/BestOCRMCPCoreTests/ServerTests.swift`

**Interfaces:**
- Produces: `BestOCRMCPServer` actor: `init(registry:EngineRegistry = .standard(), runLog:RunLog = .default(), evidenceURL:URL = EvidenceStore.defaultURL())`, `run() async throws`, internal `static defineTools() -> [Tool]`, `dispatch(name:arguments:) async throws -> String`, `execute(name:arguments:) async -> CallTool.Result`.
- Tools: `ocr` (input_path req, engine req, out_dir, dpi, pages, lang, doc_type, model, async), `recommend` (doc_type req, lang, priority, math), `list_engines`, `list_models`, `ocr_status` (job_id req), `ocr_result` (job_id req).

Key dispatch logic (complete in implementation):

```swift
import BestOCRKit
import Foundation
import MCP

/// bestOCR's MCP surface (spec §7 Flow A; bestASR #80 pattern): long-lived
/// stdio server linking BestOCRKit directly. VLM warmth lives in the Ollama
/// server (keep_alive); this process contributes persistent probes + the
/// single-flight gate that stops concurrent heavy OCR from overloading the
/// local model server or Python tools.
public actor BestOCRMCPServer {
    let registry: EngineRegistry
    let runLog: RunLog
    let evidenceURL: URL
    let server: Server
    let ocrGate = SingleFlight()
    let jobs = JobRegistry()
    static let resultWaitCap: Duration = .seconds(25)

    public init(registry: EngineRegistry = .standard(), runLog: RunLog = .default(),
                evidenceURL: URL = EvidenceStore.defaultURL()) { … }

    public func run() async throws {
        await registerHandlers()
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
    …
}
```

- `ocr` dispatch: parse args outside the gate (fail fast); `--model` override rebuilds the chosen VLM engine (same logic as CLI `Run`); work closure = `ocrGate.run { RunPipeline.execute(…) }` rendered as `✓ <engine>: N page(s) in Xs\nmarkdown: <path>\nmeta: <path>` (+ repetition-guard warning line when flagged); `async=true` → `jobs.start(work)` returns `{"job_id": …}` text.
- `recommend` dispatch: `EvidenceStore.load(from: evidenceURL)` + `Recommender.recommend`, rendered exactly like the CLI (RANKED/EVIDENCE-PENDING header + numbered entries + citations).
- `list_engines`: probeAll table (same columns as CLI).
- `list_models`: one line per `ModelProfile` (id, default tag, prompt kind, output level) + pointer to `evidence/candidates.json` tiers.
- `ocr_status` / `ocr_result`: registry poll (`resultWaitCap` long-poll).

Tests (stub-registry based, no live engines):

```swift
import Foundation
import Testing
@testable import BestOCRMCPCore
@testable import BestOCRKit

struct ServerTests {
    // Stub engine (local to this target; BestOCRKitTests' StubEngine is invisible here).
    struct MCPStubEngine: OCREngine { … same shape as StubEngine, outputLevel param … }

    func makeServer(text: String = "STUB") -> (BestOCRMCPServer, URL) { … tmp runlog + stub registry … }

    @Test func toolListAndDispatchAgree() async {
        let names = Set(BestOCRMCPServer.defineTools().map(\.name))
        #expect(names == ["ocr", "recommend", "list_engines", "list_models", "ocr_status", "ocr_result"])
        // Every advertised tool dispatches to something other than unknown-tool.
        let (server, _) = makeServer()
        for name in names {
            let result = await server.execute(name: name, arguments: [:])
            let text = …firstText(result)…
            #expect(!text.contains("unknown tool"), "\(name) fell through dispatch")
        }
    }

    @Test func unknownToolIsLoudError() async { … execute(name: "nope") → isError true, message contains "unknown tool" … }

    @Test func ocrHappyPathWritesOutputs() async throws { … fixture image + stub engine → dispatch ocr → reply contains "✓ stub", files exist, runlog has 1 line … }

    @Test func ocrMissingArgIsError() async { … execute("ocr", ["engine": .string("stub")]) → isError, mentions input_path … }

    @Test func asyncOCRRoundTrip() async throws { … dispatch ocr with async=true → job_id; ocr_result(job_id) → contains "✓ stub"; ocr_status → done … }

    @Test func recommendEvidencePendingRendered() async { … dispatch recommend doc_type math_pdf → contains "EVIDENCE-PENDING" … }
}
```

Steps: tests RED → implement Server.swift → GREEN → commit `feat: BestOCRMCPServer — 6 tools, single-flight OCR gate, async jobs`.

---

### Task 3: `bestocr-mcp` main + stdio smoke

**Files:**
- Create: `Sources/bestocr-mcp/main.swift`

```swift
import BestOCRMCPCore

// Thin entry — everything testable lives in BestOCRMCPCore.
let server = BestOCRMCPServer()
try await server.run()
```

Smoke (build then drive the stdio protocol by hand):

```bash
set -o pipefail
swift build 2>&1 | tail -1
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 | .build/debug/bestocr-mcp 2>/dev/null | python3 -c "import json,sys; [print(json.loads(l).get('result',{}).get('tools') and [t['name'] for t in json.loads(l)['result']['tools']] or 'init-ok') for l in sys.stdin if l.strip()]"
```

Expected: `init-ok` then the six tool names. Commit `feat: bestocr-mcp executable (stdio MCP server)`.

---

### Task 4: Embed adapter scripts (single-binary distribution)

**Files:**
- Create: `Sources/BestOCRKit/Adapters/AdapterScripts.swift` — the three `.py` contents as `static let` strings (`AdapterScripts.script(for tool: String) -> String?`)
- Modify: `Sources/BestOCRKit/Engines/ExternalToolEngine.swift` — `scriptURL()` materializes the embedded script to `~/.bestocr/adapters/bestocr-<tool>-adapter.py` (rewrite when content differs; `BESTOCR_ADAPTER_DIR` env override for tests), dropping `Bundle.module`
- Modify: `Package.swift` — remove `resources: [.copy("Adapters")]`; delete the three `.py` files (content now lives in AdapterScripts.swift; git history keeps the originals)
- Test: extend `ExternalToolEngineTests` — `adapterScriptMaterializesAndRefreshes()` (materialize → file exists; corrupt file on disk → scriptURL() rewrites it)

Steps: test RED → implement → full `swift test` GREEN (rapidocr/cnocr integration now exercise the materialized path) → commit `feat: embed adapter scripts for single-binary distribution`.

---

### Task 5: Plugin marketplace files

**Files:**
- Create: `.claude-plugin/marketplace.json` (name `bestocr`, owner PsychQuant, plugin `./plugins/bestocr`)
- Create: `plugins/bestocr/.claude-plugin/plugin.json` (name `bestocr`, version `0.3.0`)
- Create: `plugins/bestocr/.mcp.json` (`bestocr` stdio server → `${CLAUDE_PLUGIN_ROOT}/bin/bestocr-mcp-wrapper.sh`)
- Create: `plugins/bestocr/bin/bestocr-mcp-wrapper.sh` (adapt bestASR wrapper: REPO=`PsychQuant/bestOCR`, BINARY_NAME=`bestocr-mcp`; version sidecar `~/bin/.bestocr-mcp.version`; pinned tag `v<version>` → fallback latest; atomic mv; chmod +x)

Validation: `bash -n` the wrapper; `python3 -m json.tool` each json. Commit `feat: bestocr Claude plugin (marketplace + wrapper auto-download)`.

---

### Task 6: Release pipeline — Makefile + notarized GitHub release

**Files:**
- Create: `Makefile` — targets: `build-release` (arm64 `swift build -c release`), `sign` (codesign `--options runtime --timestamp` with `$DEVELOPER_ID`), `notarize` (zip → `xcrun notarytool submit --keychain-profile $NOTARY_PROFILE --wait`), `release-signed` (all three + sha256 sidecars for `bestocr` + `bestocr-mcp`)

Steps:
1. `xcrun notarytool history --keychain-profile che-mcps-notary | head -3` — verify credentials alive (401 → STOP, report to user; user-only re-setup).
2. `make release-signed` (notarize round-trip 2–10 min).
3. `codesign -dv` + `spctl -a -t open --context context:primary-signature` sanity on both binaries.
4. `gh release create v0.3.0 bestocr-mcp bestocr *.sha256 --title … --notes …` on PsychQuant/bestOCR; wrapper's pinned-tag path now resolves.
5. Commit `feat: sign+notarize release pipeline (Makefile)`.

---

### Task 7: README + changelog + full verification

- README: M3 status paragraph (MCP tools, plugin install one-liner `claude plugin marketplace add PsychQuant/bestOCR` + `claude plugin install bestocr@bestocr`), Usage additions.
- `changelog/20260722_m3-mcp-plugin-notarize.md`.
- `set -o pipefail; swift test | tail -1` ALL PASS; release build; stdio smoke rerun.
- Commit `docs: README M3 + changelog`.

---

## Plan Self-Review (done at authoring time)

- **Spec coverage (M3)**: MCP server + warm/persistent process + async jobs (§7 Flow A) → T1–T3; plugin marketplace → T5; notarize pipeline → T6; single-binary integrity (implicit distribution requirement) → T4. Out of scope: auto-routing `engine:"auto"` (needs run↔recommend wiring — noted for M4/backlog), skills (`/bestocr:ocr` etc. — deferred to a plugin iteration; .mcp.json ships first, matching bestASR's early versions).
- **Placeholder scan**: T2 Server test bodies are abbreviated with `…` where they repeat established patterns — each names its exact assertion; implementer (this session) holds full context. All other code complete.
- **Type consistency**: JobRegistry/SingleFlight signatures match bestASR source exactly (verbatim port); Server consumes only public/`@testable` BestOCRKit API that exists as of M2 (`RunPipeline.execute`, `Recommender.recommend`, `EngineRegistry.standard`, `ModelProfile.all`).
