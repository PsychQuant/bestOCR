# bestOCR M4 — Cloud Reference + compare + evidence ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship spec milestone M4: `CloudReferenceEngine` (Claude/OpenAI/Gemini vision over raw HTTPS, reference-tier only), `bestocr compare` (local vs cloud side-by-side with a named overlap metric), and `bestocr evidence ingest` (explicit runlog → T2 rows gate) — closing the full evidence loop (run → ingest → RANKED recommend).

**Architecture:** One `CloudReferenceEngine` parameterized by a `CloudProvider` config (key env var, default model + env override, request builder, response parser — all pure and unit-testable with canned JSON). `family == .cloudReference` means the existing Recommender filter already excludes them from rankings. `Comparator.tokenRecall` is a pure, versioned formula. `EvidenceIngest` converts a runlog entry to `speed.ms_per_page` T2 rows and appends JSONL.

**Tech Stack:** As M3. Cloud calls are raw HTTPS via URLSession (Swift has no official Anthropic SDK — per claude-api skill guidance, raw HTTP is the correct surface; shapes below follow the skill's cURL reference).

## Global Constraints

- All M1–M3 global constraints hold; `set -o pipefail` on verification chains.
- **Cloud is reference-only** (spec §6.1.3): `.cloudReference` family — never enters recommend rankings (already enforced in `Recommender`); explicit `run`/`compare` use is allowed (comparison/proofreading aid).
- API keys via env only: `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY`. Probe reports unavailable + export hint when absent. Keys never logged, never in condition tuples.
- Claude request per claude-api skill: `POST https://api.anthropic.com/v1/messages`, headers `x-api-key` + `anthropic-version: 2023-06-01`, base64 image block before text block, default model `claude-opus-4-8` (skill mandate), `max_tokens: 16000`; check `stop_reason == "refusal"` before reading content. Model overridable via `BESTOCR_CLAUDE_MODEL`.
- OpenAI: `POST https://api.openai.com/v1/chat/completions`, `Authorization: Bearer`, `image_url` data-URI content part; default `gpt-4o`, override `BESTOCR_OPENAI_MODEL`. Gemini: `POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent` with `x-goog-api-key` header, `inline_data` part; default `gemini-2.5-flash`, override `BESTOCR_GEMINI_MODEL`. Defaults are data (env-overridable), parsers defensive.
- Named-formula rule (schema.md hard rule 2): the compare metric is `quality.token_recall_vs_cloud@v1` = |multiset ∩ of normalized tokens| / |reference tokens|; normalization = lowercase + strip non-alphanumerics per token. Compare output labels the formula; it is NOT word_recall vs pdftotext and must never be conflated with it.
- Ingest (spec §6.2): explicit, human-triggered; M4 ingests `speed.ms_per_page` only (quality needs a reference the runlog doesn't carry — documented limitation); rows tier T2, source `runlog:<id>`; thermal caveat when any page was non-nominal (schema hard rule 5).

---

### Task 1: CloudProvider + CloudReferenceEngine

**Files:**
- Create: `Sources/BestOCRKit/Engines/CloudProvider.swift`
- Create: `Sources/BestOCRKit/Engines/CloudReferenceEngine.swift`
- Test: `Tests/BestOCRKitTests/CloudReferenceEngineTests.swift`

**Interfaces:**
- Produces: `CloudProvider` enum (`.claude/.openai/.gemini`) with `id` ("cloud.claude"…), `keyEnv`, `resolvedModel`, `makeRequest(imageData:mediaType:prompt:key:) -> URLRequest`, `parseText(from: Data) throws -> String`; `CloudReferenceEngine(provider:)` conforming `OCREngine` with `family == .cloudReference`.

Tests (unit, no network — request shape + parser from canned JSON):

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct CloudReferenceEngineTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47])

    @Test func identitiesAndFamilies() {
        for provider in CloudProvider.allCases {
            let engine = CloudReferenceEngine(provider: provider)
            #expect(engine.id == provider.id)
            #expect(engine.family == .cloudReference)
            #expect(engine.capabilities.needsNetwork)
        }
        #expect(CloudProvider.allCases.map(\.id) == ["cloud.claude", "cloud.openai", "cloud.gemini"])
    }

    @Test func claudeRequestShape() throws {
        let request = CloudProvider.claude.makeRequest(
            imageData: png, mediaType: "image/png", prompt: "OCR this", key: "sk-test")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-4-8")   // skill-mandated default
        let content = try #require(((json["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.first?["type"] as? String == "image")    // image before text
        #expect(content.last?["type"] as? String == "text")
    }

    @Test func claudeParserReadsTextAndRejectsRefusal() throws {
        let ok = #"{"content":[{"type":"text","text":"HELLO"}],"stop_reason":"end_turn"}"#
        #expect(try CloudProvider.claude.parseText(from: Data(ok.utf8)) == "HELLO")
        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        #expect(throws: OCREngineError.self) {
            _ = try CloudProvider.claude.parseText(from: Data(refusal.utf8))
        }
    }

    @Test func openAIAndGeminiParsers() throws {
        let openai = #"{"choices":[{"message":{"content":"WORLD"}}]}"#
        #expect(try CloudProvider.openai.parseText(from: Data(openai.utf8)) == "WORLD")
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"A"},{"text":"B"}]}}]}"#
        #expect(try CloudProvider.gemini.parseText(from: Data(gemini.utf8)) == "AB")
    }

    @Test func probeReflectsKeyEnv() async {
        unsetenv("ANTHROPIC_API_KEY")
        let engine = CloudReferenceEngine(provider: .claude)
        guard case .unavailable(let reason, let hint) = await engine.probe() else {
            Issue.record("expected unavailable without key")
            return
        }
        #expect(reason.contains("ANTHROPIC_API_KEY"))
        #expect(hint?.contains("export ANTHROPIC_API_KEY") == true)
        setenv("ANTHROPIC_API_KEY", "sk-test", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        #expect(await engine.probe() == .available)
    }

    @Test func modelEnvOverride() {
        setenv("BESTOCR_CLAUDE_MODEL", "claude-haiku-4-5", 1)
        defer { unsetenv("BESTOCR_CLAUDE_MODEL") }
        #expect(CloudProvider.claude.resolvedModel == "claude-haiku-4-5")
    }
}
```

Implementation sketch (complete in code): `CloudProvider: String, CaseIterable` with switch-based `makeRequest`/`parseText` per the Global Constraints shapes; `CloudReferenceEngine.recognize` loops pages → read data → detect media type by extension (png/jpeg) → `makeRequest` → `URLSession.shared.data(for:)` → non-2xx → `OCREngineError` with body tail → `parseText`; condition tuple `(model: resolvedModel, quant: "n/a", platform: provider.rawValue, …)`. Timeout 120 s per page.

Steps: tests RED → implement → GREEN → commit `feat: CloudReferenceEngine — Claude/OpenAI/Gemini vision over raw HTTPS (reference tier)`.

---

### Task 2: Registry roster (11 engines)

- Modify `EngineRegistry.standard()`: append `CloudProvider.allCases.map { CloudReferenceEngine(provider: $0) }` after the VLM engines.
- Update `standardRosterHasEightEngines` → `standardRosterHasElevenEngines` expecting `[…, "cloud.claude", "cloud.openai", "cloud.gemini"]`.
- Add a Recommender guard test in `RecommenderTests`: a registry containing a `CloudReferenceEngine` never yields its id in `recommend` entries even with matching evidence rows (spec §6.1.3, now actually exercised).
- Smoke: `.build/debug/bestocr list-engines` shows 11 rows, cloud rows `✗ … export …` (no keys in this shell).
- Commit `feat: register cloud reference engines (probe-gated by API-key env)`.

---

### Task 3: Comparator + `bestocr compare`

**Files:**
- Create: `Sources/BestOCRKit/Recommend/Comparator.swift`
- Create: `Sources/bestocr/CompareCommand.swift`; modify `BestOCRMain.swift` (add subcommand)
- Test: `Tests/BestOCRKitTests/ComparatorTests.swift`

**Interfaces:**
- Produces: `Comparator.formulaID == "quality.token_recall_vs_cloud@v1"`, `Comparator.normalize(_ text: String) -> [String]`, `Comparator.tokenRecall(candidate: String, reference: String) -> Double` (multiset intersection over reference count; empty reference → 0).

```swift
import Testing
@testable import BestOCRKit

struct ComparatorTests {
    @Test func perfectAndPartialRecall() {
        #expect(Comparator.tokenRecall(candidate: "Hello, World!", reference: "hello world") == 1.0)
        #expect(Comparator.tokenRecall(candidate: "hello", reference: "hello world") == 0.5)
        #expect(Comparator.tokenRecall(candidate: "", reference: "hello") == 0.0)
        #expect(Comparator.tokenRecall(candidate: "x", reference: "") == 0.0)
    }

    @Test func multisetCountsDuplicates() {
        // reference has "a" twice; candidate supplies it once → 1 of 3 matched + b,c…
        #expect(Comparator.tokenRecall(candidate: "a b", reference: "a a b") == 2.0 / 3.0)
    }

    @Test func normalizationStripsPunctuationAndCase() {
        #expect(Comparator.normalize("Héllo, WORLD—42!") == ["héllo", "world", "42"])
    }

    @Test func formulaIsNamedAndVersioned() {
        #expect(Comparator.formulaID == "quality.token_recall_vs_cloud@v1")
    }
}
```

CLI `compare`: args `input`, `--engine` (local, required), `--vs` (default `cloud.claude`), `--dpi/--pages/--lang/--doc-type/--out`. Flow: probe both (either unavailable → clear error) → normalize ONCE → `recognize` on both with the same pages → write `<stem>.<engine>.md` per side → print per-side timing + `token_recall_vs_cloud@v1 = <value>` + the reminder line `reference is a cloud model, not ground truth — not comparable to word_recall vs pdftotext`.

Steps: tests RED → implement → GREEN → build + `--help` smoke (live cloud call requires a key; guarded live smoke only if `ANTHROPIC_API_KEY` set) → commit `feat: Comparator + bestocr compare (local vs cloud reference, named formula)`.

---

### Task 4: EvidenceIngest + `bestocr evidence ingest` (full-circle)

**Files:**
- Create: `Sources/BestOCRKit/Recommend/EvidenceIngest.swift`
- Create: `Sources/bestocr/EvidenceCommand.swift`; modify `BestOCRMain.swift` (add `Evidence` group with `Ingest` subcommand)
- Test: `Tests/BestOCRKitTests/EvidenceIngestTests.swift`

**Interfaces:**
- Produces: `EvidenceIngest.rows(from: RunLogEntry) -> [EvidenceRow]` (one `speed.ms_per_page` row: mean over pages × 1000, tier "T2", source `runlog:<id>`, caveat listing non-nominal thermal pages or nil); `EvidenceIngest.findEntry(id: String, in: URL) throws -> RunLogEntry` (exact or unique-prefix match; ambiguous/missing → loud error); `EvidenceIngest.append(_ rows: [EvidenceRow], to: URL) throws` (JSONL append, creates parent dir).

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct EvidenceIngestTests {
    func entry(seconds: [Double], thermal: String = "nominal") -> RunLogEntry {
        let condition = ConditionTuple(model: "vision", quant: "n/a", dpi: 150,
                                       docType: "screenshot", platform: "vision",
                                       hardware: "test", instrument: BestOCRVersion.string)
        let result = OCRResult(engineID: "vision",
                               pages: seconds.enumerated().map { i, s in
                                   PageResult(page: i + 1, text: "x", seconds: s,
                                              thermalState: thermal, degenerateFlagged: false)
                               }, condition: condition)
        return RunLogEntry(from: result, input: "/a.png", output: "/o.md")
    }

    @Test func speedRowFromMeanPageSeconds() {
        let rows = EvidenceIngest.rows(from: entry(seconds: [1.0, 3.0]))
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.estimand == "speed.ms_per_page")
        #expect(row.value == 2000)
        #expect(row.tier == "T2")
        #expect(row.source.hasPrefix("runlog:"))
        #expect(row.caveat == nil)
        #expect(row.condition.docType == "screenshot")
    }

    @Test func thermalCaveatWhenNotNominal() {
        let rows = EvidenceIngest.rows(from: entry(seconds: [1.0], thermal: "serious"))
        #expect(rows[0].caveat?.contains("serious") == true)
    }

    @Test func findEntryByUniquePrefixAndLoudFailures() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlog-\(UUID().uuidString).jsonl")
        let log = RunLog(fileURL: file)
        let e1 = entry(seconds: [1.0]); try log.append(e1)
        let e2 = entry(seconds: [2.0]); try log.append(e2)
        let found = try EvidenceIngest.findEntry(id: String(e1.id.prefix(8)), in: file)
        #expect(found.id == e1.id)
        #expect(throws: OCREngineError.self) {
            _ = try EvidenceIngest.findEntry(id: "zzzz-none", in: file)
        }
    }

    @Test func appendWritesLoadableRows() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rows-\(UUID().uuidString).jsonl")
        try EvidenceIngest.append(EvidenceIngest.rows(from: entry(seconds: [1.5])), to: file)
        try EvidenceIngest.append(EvidenceIngest.rows(from: entry(seconds: [2.5])), to: file)
        let store = try EvidenceStore.load(from: file)
        #expect(store.rows.count == 2)
        #expect(store.rows.allSatisfy { $0.estimand == "speed.ms_per_page" })
    }
}
```

CLI: `bestocr evidence ingest <run-id>` — resolves runlog (`BESTOCR_RUNLOG`/default), finds entry, prints the row(s), appends to `EvidenceStore.defaultURL()` (`BESTOCR_EVIDENCE` honored), prints where they landed.

**Full-circle E2E smoke (the M4 crown):**

```bash
set -o pipefail
export BESTOCR_RUNLOG=/tmp/m4-runlog.jsonl BESTOCR_EVIDENCE=/tmp/m4-rows.jsonl
rm -f $BESTOCR_RUNLOG $BESTOCR_EVIDENCE
.build/debug/bestocr run /tmp/bestocr-smoke.png --engine vision --doc-type screenshot --out /tmp/m4-out
RUN_ID=$(python3 -c "import json; print(json.load(open('/tmp/m4-runlog.jsonl'))['id'])")
.build/debug/bestocr evidence ingest "$RUN_ID"
.build/debug/bestocr recommend --doc-type screenshot --priority speed
```

Expected: final command prints `RANKED (T2 …)` with `vision` ranked from the just-ingested row, citing `runlog:<id>` — the evidence loop is closed with real data.

Commit `feat: evidence ingest — explicit runlog→T2 gate closes the evidence loop`.

---

### Task 5: Docs + full verification

- README: M4 status (all four milestones shipped), Usage additions (`compare`, `evidence ingest`), cloud key envs.
- `CLAUDE.md`: milestone list all ✅; add cloud/env notes.
- `changelog/20260722_m4-cloud-compare-ingest.md`.
- `set -o pipefail; swift test | tail -1` ALL PASS; release build; 11-row list-engines.
- Commit `docs: README + CLAUDE.md + changelog for M4`.

---

## Plan Self-Review (done at authoring time)

- **Spec coverage (M4)**: §5.4 cloud row → T1–T2; §7 `compare` → T3; §6.2 explicit ingest → T4; §6.1.3 ranking exclusion now has a direct test → T2. Deliberately deferred (recorded in README backlog): auto-route `engine:"auto"` in run/MCP, fallback chain, quality-estimand ingest (needs reference), PaddleOCR-VL `\( \)` → `$` delimiter normalization (spec Y3).
- **Placeholder scan**: Task 1 implementation is sketched with exact shapes in Global Constraints + full tests pinning behavior; all other tasks carry complete code/commands. Executor is this session with skill context loaded.
- **Type consistency**: `EvidenceRow(estimand:value:condition:tier:source:caveat:)` matches M2; `RunLogEntry(from:input:output:)` matches M1; `CloudProvider.id` strings match roster test; `Comparator.formulaID` string used in both test and CLI output.
