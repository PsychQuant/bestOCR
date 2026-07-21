# bestOCR M2 — External-Tool Adapters + recommend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship spec milestone M2: external-process Python adapters (rapidocr, cnocr, surya) behind the bestASR protocol-v1 pattern, plus `recommend` with the honest evidence-pending mode (spec §6.1).

**Architecture:** A single `ExternalToolEngine` (Swift) speaks OCR protocol v1 to per-tool Python adapter scripts bundled as SPM resources; probe runs the adapter's `probe` subcommand. `recommend` = capability filter + `EvidenceStore` (JSONL rows per evidence/schema.md) + tier-disciplined `Recommender`.

**Tech Stack:** As M1 (Swift 6.1 / Swift Testing), plus: Python 3.13 (python.org framework at `/usr/local/bin/python3`; adapters take `BESTOCR_PYTHON` override), rapidocr 3.6.0 + cnocr 2.3.2.2 (Python API), surya-ocr 0.17.1 (via its `surya_ocr` CLI).

## Global Constraints

- All M1 global constraints hold (no `repos/measureOCR` changes, condition-tuple keys, probe-before-dispatch, Swift Testing, conventional commits, no attribution footer).
- Protocol v1 (mirrors bestASR ExternalProcessEngine, design D1/D3): spawn over an **argv array, never a shell**; consume exactly **the last non-empty stdout line** as one JSON object (model-download / objc-dylib noise on stdout or stderr must not break parsing); non-zero exit → typed `OCREngineError` with stderr tail; timeout enforced.
- Adapter contract:
  - `<python> <adapter.py> probe` → exit 0 with `{"protocol":1,"ok":true,"tool":"<name>","version":"…"}` or `{"protocol":1,"ok":false,"reason":"…"}`
  - `<python> <adapter.py> ocr --image <path> [--lang <csv>]` → `{"protocol":1,"text":"…"}`; failure = non-zero exit + reason on stderr
- **nougat is deferred, not integrated**: its install is stranded in `~/.local/pipx/venvs/pip/` (python3.12, not importable from the main interpreter) and upstream is archived. The adapter architecture makes later re-admission a script-drop; do NOT write a nougat adapter in M2. Record the deferral in README (Task 6).
- Integration tests: rapidocr/cnocr guarded by a live in-test probe (visible early-return skip); surya additionally opt-in via `BESTOCR_TEST_SURYA` env (first run downloads ~GB of models).
- Evidence rows file: `evidence/rows.jsonl` (may be absent → empty store → evidence-pending). `BESTOCR_EVIDENCE` env overrides the path.
- Tier discipline (schema.md hard rules): a ranking never contains two tiers; T3 rows are never ranked; every ranked answer cites its rows.

---

### Task 1: ExternalToolEngine + rapidocr adapter (the protocol seam)

**Files:**
- Create: `Sources/BestOCRKit/Adapters/bestocr-rapidocr-adapter.py`
- Create: `Sources/BestOCRKit/Engines/ExternalToolEngine.swift`
- Modify: `Package.swift` (BestOCRKit target gains `resources: [.copy("Adapters")]`)
- Test: `Tests/BestOCRKitTests/ExternalToolEngineTests.swift`

**Interfaces:**
- Consumes: `OCREngine`, `EngineAvailability`, `EngineCapabilities`, `OCRRequest/OCRResult/PageResult/ConditionTuple`, `Subprocess`, `HostInfo`, `Fixtures`.
- Produces: `ExternalToolEngine(tool:String, capabilities:EngineCapabilities, installHint:String, python:String? = nil, script:URL? = nil, timeout:TimeInterval = 300)` — `id == "ext.<tool>"`, `family == .classical`; `ExternalToolEngine.locatePython() -> URL?` (honours `BESTOCR_PYTHON`); `func scriptURL() -> URL?` (override ?? `Bundle.module` `Adapters/bestocr-<tool>-adapter.py`); static helper `lastJSONLine(_ stdout: String) -> Data?`.

- [ ] **Step 1: Write the failing tests** (fake adapters exercise the protocol without heavy tools)

`Tests/BestOCRKitTests/ExternalToolEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct ExternalToolEngineTests {
    static let caps = EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                                         needsNetwork: false, memoryClass: .light)

    /// Writes a fake adapter script and returns an engine wired to it.
    func makeEngine(script: String, tool: String = "fake") throws -> ExternalToolEngine {
        let url = try Fixtures.tempDir().appendingPathComponent("adapter.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return ExternalToolEngine(tool: tool, capabilities: Self.caps,
                                  installHint: "pip install fake", script: url, timeout: 30)
    }

    @Test func identity() throws {
        let engine = try makeEngine(script: "")
        #expect(engine.id == "ext.fake")
        #expect(engine.family == .classical)
    }

    @Test func lastJSONLineSkipsNoise() {
        let noisy = "downloading model...\n50%\n{\"protocol\": 1, \"text\": \"hi\"}\n"
        let data = ExternalToolEngine.lastJSONLine(noisy)
        #expect(data != nil)
        let noJSON = "no json here\nat all\n"
        #expect(ExternalToolEngine.lastJSONLine(noJSON) == nil)
    }

    @Test func happyProbeAndOCR() async throws {
        let engine = try makeEngine(script: """
        import json, sys
        if sys.argv[1] == "probe":
            print("noise line")
            print(json.dumps({"protocol": 1, "ok": True, "tool": "fake", "version": "1"}))
        else:
            print(json.dumps({"protocol": 1, "text": "FAKE TEXT"}))
        """)
        #expect(await engine.probe() == .available)
        let img = try Fixtures.textImage("X")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], docType: "screenshot"))
        #expect(result.pages[0].text == "FAKE TEXT")
        #expect(result.condition.platform == "python")
        #expect(result.condition.model == "fake")
        #expect(result.condition.quant == "n/a")
    }

    @Test func probeNotOKReportsReasonAndHint() async throws {
        let engine = try makeEngine(script: """
        import json
        print(json.dumps({"protocol": 1, "ok": False, "reason": "No module named 'fake'"}))
        """)
        guard case .unavailable(let reason, let hint) = await engine.probe() else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("No module named"))
        #expect(hint == "pip install fake")
    }

    @Test func ocrFailureSurfacesStderr() async throws {
        let engine = try makeEngine(script: """
        import sys
        if sys.argv[1] == "probe":
            import json; print(json.dumps({"protocol": 1, "ok": True, "tool": "fake", "version": "1"}))
        else:
            print("boom: model exploded", file=sys.stderr)
            sys.exit(3)
        """)
        let img = try Fixtures.textImage("X")
        do {
            _ = try await engine.recognize(OCRRequest(
                pages: [PageImage(pageNumber: 1, url: img)], docType: "unspecified"))
            Issue.record("expected throw")
        } catch let error as OCREngineError {
            #expect(error.message.contains("exit 3"))
            #expect(error.message.contains("model exploded"))
        }
    }

    @Test func unsupportedProtocolVersionIsRejected() async throws {
        let engine = try makeEngine(script: """
        import json, sys
        print(json.dumps({"protocol": 2, "ok": True, "tool": "fake", "version": "1"}))
        """)
        guard case .unavailable(let reason, _) = await engine.probe() else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("protocol"))
    }

    // Live integration — visible early-return skip when rapidocr is absent.
    @Test func rapidocrRecognizesFixture() async throws {
        let engine = ExternalToolEngine.rapidocr()
        guard case .available = await engine.probe() else {
            print("SKIP: rapidocr unavailable on this machine")
            return
        }
        let img = try Fixtures.textImage("HELLO 42")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], languages: ["en"], docType: "screenshot"))
        #expect(result.pages[0].text.contains("HELLO"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExternalToolEngineTests 2>&1 | grep -m1 "error:"`
Expected: FAIL — `cannot find 'ExternalToolEngine' in scope`.

- [ ] **Step 3: Write the adapter script**

`Sources/BestOCRKit/Adapters/bestocr-rapidocr-adapter.py`:

```python
#!/usr/bin/env python3
"""bestOCR external-tool adapter for RapidOCR (OCR protocol v1).

probe        -> {"protocol":1,"ok":true,"tool":"rapidocr","version":"..."} (exit 0)
                {"protocol":1,"ok":false,"reason":"..."}                    (exit 0)
ocr --image  -> {"protocol":1,"text":"..."}; failure: non-zero exit + stderr.

Containment (bestASR design D3): upstream churn breaks THIS file, never the
host. The host reads only the LAST stdout line, so download noise is safe.
"""
import argparse
import json
import sys


def probe() -> None:
    try:
        import rapidocr
        version = getattr(rapidocr, "__version__", "unknown")
        print(json.dumps({"protocol": 1, "ok": True, "tool": "rapidocr", "version": version}))
    except Exception as exc:  # noqa: BLE001 — probe reports, never raises
        print(json.dumps({"protocol": 1, "ok": False, "reason": f"{type(exc).__name__}: {exc}"}))


def ocr(image: str, lang: str) -> None:
    from rapidocr import RapidOCR
    engine = RapidOCR()
    result = engine(image)
    texts: list[str] = []
    if result is not None:
        txts = getattr(result, "txts", None)
        if txts:
            texts = [t for t in txts if t]
        elif isinstance(result, (list, tuple)):  # older tuple-shaped outputs
            for item in result:
                if isinstance(item, (list, tuple)) and len(item) >= 2:
                    texts.append(str(item[1]))
    print(json.dumps({"protocol": 1, "text": "\n".join(texts)}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-rapidocr-adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("probe")
    p_ocr = sub.add_parser("ocr")
    p_ocr.add_argument("--image", required=True)
    p_ocr.add_argument("--lang", default="")
    args = parser.parse_args()
    if args.command == "probe":
        probe()
        return
    try:
        ocr(args.image, args.lang)
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Write ExternalToolEngine + register the resource**

In `Package.swift`, change the BestOCRKit target to:

```swift
        .target(
            name: "BestOCRKit",
            dependencies: [
                .product(name: "OCRCore", package: "ocr-swift"),
                .product(name: "PDFToLaTeXCore", package: "pdf-to-latex-swift"),
            ],
            resources: [.copy("Adapters")]
        ),
```

`Sources/BestOCRKit/Engines/ExternalToolEngine.swift`:

```swift
import Foundation

/// External Python-tool engine speaking OCR protocol v1 (spec §5.4; bestASR
/// ExternalProcessEngine pattern). One instance per tool; the adapter script
/// owns the tool's runtime quirks, the host owns only the protocol.
public struct ExternalToolEngine: OCREngine {
    static let supportedProtocols: Set<Int> = [1]

    public let tool: String
    public let capabilities: EngineCapabilities
    public let installHint: String
    let pythonOverride: String?
    let scriptOverride: URL?
    let timeout: TimeInterval

    public var id: String { "ext.\(tool)" }
    public let family = EngineFamily.classical

    public init(tool: String, capabilities: EngineCapabilities, installHint: String,
                python: String? = nil, script: URL? = nil, timeout: TimeInterval = 300) {
        self.tool = tool
        self.capabilities = capabilities
        self.installHint = installHint
        self.pythonOverride = python
        self.scriptOverride = script
        self.timeout = timeout
    }

    /// `BESTOCR_PYTHON` env override, else `python3` from PATH.
    public static func locatePython() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BESTOCR_PYTHON"] {
            return FileManager.default.isExecutableFile(atPath: override)
                ? URL(fileURLWithPath: override) : nil
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/python3"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    func scriptURL() -> URL? {
        if let scriptOverride { return scriptOverride }
        return Bundle.module.url(forResource: "bestocr-\(tool)-adapter",
                                 withExtension: "py", subdirectory: "Adapters")
    }

    /// Protocol reads exactly one JSON object: the LAST stdout line that
    /// parses as JSON (download noise above it is ignored).
    static func lastJSONLine(_ stdout: String) -> Data? {
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            let data = Data(trimmed.utf8)
            if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        }
        return nil
    }

    struct ProbeReply: Decodable {
        let `protocol`: Int
        let ok: Bool
        let tool: String?
        let version: String?
        let reason: String?
    }

    struct OCRReply: Decodable {
        let `protocol`: Int
        let text: String
    }

    public func probe() async -> EngineAvailability {
        guard let python = Self.locatePython() else {
            return .unavailable(reason: "python3 not found on PATH",
                                installHint: "install Python 3 or set BESTOCR_PYTHON")
        }
        guard let script = scriptURL() else {
            return .unavailable(reason: "adapter script for \(tool) missing from bundle",
                                installHint: nil)
        }
        let run: Subprocess.Result
        do {
            run = try Subprocess.run(python, arguments: [script.path, "probe"], timeout: 60)
        } catch {
            return .unavailable(reason: "probe failed: \(error.localizedDescription)",
                                installHint: installHint)
        }
        guard run.exitCode == 0,
              let data = Self.lastJSONLine(run.stdout),
              let reply = try? JSONDecoder().decode(ProbeReply.self, from: data) else {
            let tail = run.stderr.suffix(200).trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: "probe exited \(run.exitCode) without a protocol reply\(tail.isEmpty ? "" : ": \(tail)")",
                                installHint: installHint)
        }
        guard Self.supportedProtocols.contains(reply.protocol) else {
            return .unavailable(reason: "unsupported adapter protocol v\(reply.protocol)",
                                installHint: nil)
        }
        guard reply.ok else {
            return .unavailable(reason: reply.reason ?? "tool import failed",
                                installHint: installHint)
        }
        return .available
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        guard let python = Self.locatePython() else {
            throw OCREngineError(engine: id, message: "python3 not found on PATH")
        }
        guard let script = scriptURL() else {
            throw OCREngineError(engine: id, message: "adapter script missing from bundle")
        }
        var pageResults: [PageResult] = []
        for page in request.pages {
            var arguments = [script.path, "ocr", "--image", page.url.path]
            if !request.languages.isEmpty {
                arguments += ["--lang", request.languages.joined(separator: ",")]
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            let run: Subprocess.Result
            do {
                run = try Subprocess.run(python, arguments: arguments, timeout: timeout)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            guard run.exitCode == 0 else {
                let tail = run.stderr.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines)
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): adapter exit \(run.exitCode): \(tail)")
            }
            guard let data = Self.lastJSONLine(run.stdout),
                  let reply = try? JSONDecoder().decode(OCRReply.self, from: data),
                  Self.supportedProtocols.contains(reply.protocol) else {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): no protocol-v1 JSON on adapter stdout")
            }
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            pageResults.append(PageResult(page: page.pageNumber, text: reply.text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: tool, quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "python",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }
}

// MARK: - Standard tool wirings (roster entries; capabilities per tool)

extension ExternalToolEngine {
    public static func rapidocr() -> ExternalToolEngine {
        ExternalToolEngine(
            tool: "rapidocr",
            capabilities: EngineCapabilities(outputLevel: .plainText,
                                             languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                                             needsNetwork: false, memoryClass: .light),
            installHint: "pip install rapidocr")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ExternalToolEngineTests 2>&1 | tail -4`
Expected: PASS — 7 tests (incl. live rapidocr fixture recognition; first run may download small ONNX models).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/BestOCRKit/Adapters Sources/BestOCRKit/Engines/ExternalToolEngine.swift Tests/BestOCRKitTests/ExternalToolEngineTests.swift
git commit -m "feat: ExternalToolEngine (OCR protocol v1) + rapidocr adapter"
```

---

### Task 2: cnocr + surya adapters

**Files:**
- Create: `Sources/BestOCRKit/Adapters/bestocr-cnocr-adapter.py`
- Create: `Sources/BestOCRKit/Adapters/bestocr-surya-adapter.py`
- Modify: `Sources/BestOCRKit/Engines/ExternalToolEngine.swift` (append two wirings to the extension)
- Test: `Tests/BestOCRKitTests/ExternalToolAdaptersTests.swift`

**Interfaces:**
- Produces: `ExternalToolEngine.cnocr()`, `ExternalToolEngine.surya()`.

- [ ] **Step 1: Write the failing tests**

`Tests/BestOCRKitTests/ExternalToolAdaptersTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct ExternalToolAdaptersTests {
    @Test func wiringIdentities() {
        #expect(ExternalToolEngine.cnocr().id == "ext.cnocr")
        #expect(ExternalToolEngine.surya().id == "ext.surya")
        #expect(ExternalToolEngine.cnocr().capabilities.languages.contains("zh-Hant"))
    }

    // Live integration — visible early-return skip when cnocr is absent.
    @Test func cnocrRecognizesFixture() async throws {
        let engine = ExternalToolEngine.cnocr()
        guard case .available = await engine.probe() else {
            print("SKIP: cnocr unavailable on this machine")
            return
        }
        let img = try Fixtures.textImage("HELLO 42")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], languages: ["en"], docType: "screenshot"))
        #expect(result.pages[0].text.uppercased().contains("HELLO"))
    }

    // surya downloads ~GB of models on first run — opt-in only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BESTOCR_TEST_SURYA"] != nil))
    func suryaRecognizesFixture() async throws {
        let engine = ExternalToolEngine.surya()
        guard case .available = await engine.probe() else {
            print("SKIP: surya unavailable on this machine")
            return
        }
        let img = try Fixtures.textImage("HELLO 42")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], languages: ["en"], docType: "screenshot"))
        #expect(result.pages[0].text.contains("HELLO"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExternalToolAdaptersTests 2>&1 | grep -m1 "error:"`
Expected: FAIL — `type 'ExternalToolEngine' has no member 'cnocr'`.

- [ ] **Step 3: Write the two adapter scripts + wirings**

`Sources/BestOCRKit/Adapters/bestocr-cnocr-adapter.py`:

```python
#!/usr/bin/env python3
"""bestOCR external-tool adapter for CnOCR (OCR protocol v1). See rapidocr
adapter docstring for the contract."""
import argparse
import json
import sys


def probe() -> None:
    try:
        import cnocr  # noqa: F401
        from cnocr import CnOcr  # noqa: F401
        version = getattr(cnocr, "__version__", "unknown")
        if not isinstance(version, str):  # cnocr exposes a module here
            version = getattr(version, "__version__", "unknown")
        print(json.dumps({"protocol": 1, "ok": True, "tool": "cnocr", "version": str(version)}))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"protocol": 1, "ok": False, "reason": f"{type(exc).__name__}: {exc}"}))


def ocr(image: str, lang: str) -> None:
    from cnocr import CnOcr
    engine = CnOcr()
    lines = engine.ocr(image)
    texts = [str(line.get("text", "")) for line in lines if isinstance(line, dict)]
    print(json.dumps({"protocol": 1, "text": "\n".join(t for t in texts if t)}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-cnocr-adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("probe")
    p_ocr = sub.add_parser("ocr")
    p_ocr.add_argument("--image", required=True)
    p_ocr.add_argument("--lang", default="")
    args = parser.parse_args()
    if args.command == "probe":
        probe()
        return
    try:
        ocr(args.image, args.lang)
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

`Sources/BestOCRKit/Adapters/bestocr-surya-adapter.py`:

```python
#!/usr/bin/env python3
"""bestOCR external-tool adapter for surya (OCR protocol v1).

Wraps the `surya_ocr` CLI (0.17.x): runs it into a temp dir, then extracts
every text line from the result JSON, whatever its exact nesting."""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile


def probe() -> None:
    try:
        import surya  # noqa: F401
        if shutil.which("surya_ocr") is None:
            print(json.dumps({"protocol": 1, "ok": False,
                              "reason": "surya importable but surya_ocr CLI not on PATH"}))
            return
        version = getattr(surya, "__version__", "unknown")
        print(json.dumps({"protocol": 1, "ok": True, "tool": "surya", "version": str(version)}))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"protocol": 1, "ok": False, "reason": f"{type(exc).__name__}: {exc}"}))


def collect_text(node) -> list:
    out = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "text_lines" and isinstance(value, list):
                out.extend(str(line.get("text", "")) for line in value if isinstance(line, dict))
            else:
                out.extend(collect_text(value))
    elif isinstance(node, list):
        for item in node:
            out.extend(collect_text(item))
    return out


def ocr(image: str, lang: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        proc = subprocess.run(["surya_ocr", image, "--output_dir", tmp],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            print(proc.stderr[-2000:], file=sys.stderr)
            sys.exit(1)
        texts = []
        for path in sorted(glob.glob(os.path.join(tmp, "**", "*.json"), recursive=True)):
            with open(path, encoding="utf-8") as handle:
                texts.extend(collect_text(json.load(handle)))
        print(json.dumps({"protocol": 1, "text": "\n".join(t for t in texts if t)}))


def main() -> None:
    parser = argparse.ArgumentParser(prog="bestocr-surya-adapter")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("probe")
    p_ocr = sub.add_parser("ocr")
    p_ocr.add_argument("--image", required=True)
    p_ocr.add_argument("--lang", default="")
    args = parser.parse_args()
    if args.command == "probe":
        probe()
        return
    try:
        ocr(args.image, args.lang)
    except Exception as exc:  # noqa: BLE001
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
```

Append to the extension at the bottom of `ExternalToolEngine.swift`:

```swift
    public static func cnocr() -> ExternalToolEngine {
        ExternalToolEngine(
            tool: "cnocr",
            capabilities: EngineCapabilities(outputLevel: .plainText,
                                             languages: ["zh-Hans", "zh-Hant", "en"],
                                             needsNetwork: false, memoryClass: .light),
            installHint: "pip install cnocr[ort-cpu]")
    }

    public static func surya() -> ExternalToolEngine {
        ExternalToolEngine(
            tool: "surya",
            capabilities: EngineCapabilities(outputLevel: .plainText,
                                             languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                                             needsNetwork: false, memoryClass: .medium),
            installHint: "pip install surya-ocr")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ExternalToolAdaptersTests 2>&1 | tail -4`
Expected: PASS — wiring + cnocr live test (first run downloads small models); surya test skipped unless `BESTOCR_TEST_SURYA` set.

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/Adapters Sources/BestOCRKit/Engines/ExternalToolEngine.swift Tests/BestOCRKitTests/ExternalToolAdaptersTests.swift
git commit -m "feat: cnocr + surya protocol-v1 adapters"
```

---

### Task 3: Registry wiring (8-engine roster)

**Files:**
- Modify: `Sources/BestOCRKit/EngineRegistry.swift` (standard roster gains the three ext engines)
- Modify: `Tests/BestOCRKitTests/EngineRegistryTests.swift` (roster expectation)

**Interfaces:**
- Produces: `EngineRegistry.standard()` roster order `["vision", "tesseract", "ext.rapidocr", "ext.cnocr", "ext.surya", "vlm.glm-ocr", "vlm.ovisocr2", "vlm.paddleocr-vl"]`.

- [ ] **Step 1: Update the roster test (RED)**

In `EngineRegistryTests.swift`, replace the body of `standardRosterHasFiveEngines` and rename it:

```swift
    @Test func standardRosterHasEightEngines() {
        let registry = EngineRegistry.standard()
        #expect(registry.engines.map(\.id) ==
                ["vision", "tesseract", "ext.rapidocr", "ext.cnocr", "ext.surya",
                 "vlm.glm-ocr", "vlm.ovisocr2", "vlm.paddleocr-vl"])
    }
```

Run: `swift test --filter EngineRegistryTests 2>&1 | tail -3`
Expected: FAIL — roster mismatch.

- [ ] **Step 2: Update the roster (GREEN)**

In `EngineRegistry.swift`, replace the `standard` body:

```swift
    /// M2 roster: classical (Vision, tesseract, external Python tools) then
    /// one VLM engine per admitted profile.
    public static func standard(ollamaHost: String = "localhost:11434") -> EngineRegistry {
        var engines: [any OCREngine] = [
            VisionEngine(), TesseractEngine(),
            ExternalToolEngine.rapidocr(), ExternalToolEngine.cnocr(), ExternalToolEngine.surya(),
        ]
        engines.append(contentsOf: ModelProfile.all.map {
            VLMEngine(profile: $0, host: ollamaHost)
        })
        return EngineRegistry(engines: engines)
    }
```

Run: `swift test --filter EngineRegistryTests 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 3: Smoke `list-engines` and commit**

```bash
swift build 2>&1 | tail -1 && .build/debug/bestocr list-engines
```
Expected: 8 rows; `ext.rapidocr`/`ext.cnocr` probe ✓ (or ✗ with pip hint), `ext.surya` ✓ or ✗.

```bash
git add Sources/BestOCRKit/EngineRegistry.swift Tests/BestOCRKitTests/EngineRegistryTests.swift
git commit -m "feat: register external-tool engines in the standard roster"
```

---

### Task 4: WorkloadSpec + EvidenceStore

**Files:**
- Create: `Sources/BestOCRKit/Recommend/WorkloadSpec.swift`
- Create: `Sources/BestOCRKit/Recommend/EvidenceStore.swift`
- Test: `Tests/BestOCRKitTests/EvidenceStoreTests.swift`

**Interfaces:**
- Produces: `WorkloadSpec(docType:String, languages:[String], priority:Priority, needsMath:Bool)` with `enum Priority: String { case quality, speed, balanced }`; `EvidenceRow` (Codable: `estimand:String, value:Double, condition:ConditionTuple, tier:String, source:String, caveat:String?`); `EvidenceStore(rows:[EvidenceRow])`, `EvidenceStore.load(from:URL) throws -> EvidenceStore` (absent file → empty), `EvidenceStore.defaultURL()` (honours `BESTOCR_EVIDENCE`, else `evidence/rows.jsonl` under CWD), `func rows(docType:String) -> [EvidenceRow]`.

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/EvidenceStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct EvidenceStoreTests {
    static func rowJSON(model: String, tier: String, estimand: String, value: Double,
                        docType: String = "math_pdf") -> String {
        """
        {"estimand":"\(estimand)","value":\(value),"condition":{"model":"\(model)","quant":"q8_0","dpi":100,"doc_type":"\(docType)","platform":"ollama","hardware":"test","instrument":"test"},"tier":"\(tier)","source":"unit-test"}
        """
    }

    @Test func loadsJSONLAndFiltersByDocType() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rows-\(UUID().uuidString).jsonl")
        let content = [
            Self.rowJSON(model: "glm-ocr", tier: "T2", estimand: "quality.word_recall", value: 0.98),
            Self.rowJSON(model: "glm-ocr", tier: "T2", estimand: "speed.ms_per_page", value: 1981),
            Self.rowJSON(model: "vision", tier: "T2", estimand: "quality.word_recall", value: 0.91,
                         docType: "screenshot"),
        ].joined(separator: "\n")
        try content.write(to: file, atomically: true, encoding: .utf8)
        let store = try EvidenceStore.load(from: file)
        #expect(store.rows.count == 3)
        #expect(store.rows(docType: "math_pdf").count == 2)
        #expect(store.rows(docType: "screenshot").first?.condition.model == "vision")
    }

    @Test func absentFileYieldsEmptyStore() throws {
        let store = try EvidenceStore.load(
            from: URL(fileURLWithPath: "/nonexistent/rows.jsonl"))
        #expect(store.rows.isEmpty)
    }

    @Test func malformedLineThrowsWithLineNumber() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rows-\(UUID().uuidString).jsonl")
        try "not json\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: OCREngineError.self) {
            _ = try EvidenceStore.load(from: file)
        }
    }

    @Test func defaultURLHonoursEnv() {
        setenv("BESTOCR_EVIDENCE", "/tmp/custom-rows.jsonl", 1)
        defer { unsetenv("BESTOCR_EVIDENCE") }
        #expect(EvidenceStore.defaultURL().path == "/tmp/custom-rows.jsonl")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EvidenceStoreTests 2>&1 | grep -m1 "error:"`
Expected: FAIL — `cannot find 'EvidenceStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/Recommend/WorkloadSpec.swift`:

```swift
/// What the caller wants OCRed and what they optimise for (spec §6.1).
public struct WorkloadSpec: Sendable {
    public enum Priority: String, Sendable, CaseIterable {
        case quality, speed, balanced
    }

    public let docType: String
    public let languages: [String]
    public let priority: Priority
    public let needsMath: Bool

    public init(docType: String, languages: [String] = [],
                priority: Priority = .balanced, needsMath: Bool = false) {
        self.docType = docType
        self.languages = languages
        self.priority = priority
        self.needsMath = needsMath
    }
}
```

`Sources/BestOCRKit/Recommend/EvidenceStore.swift`:

```swift
import Foundation

/// One measured row per evidence/schema.md — estimand × condition × tier.
public struct EvidenceRow: Codable, Sendable {
    public let estimand: String
    public let value: Double
    public let condition: ConditionTuple
    public let tier: String       // "T1" / "T2" / "T3"
    public let source: String
    public let caveat: String?

    public init(estimand: String, value: Double, condition: ConditionTuple,
                tier: String, source: String, caveat: String? = nil) {
        self.estimand = estimand
        self.value = value
        self.condition = condition
        self.tier = tier
        self.source = source
        self.caveat = caveat
    }
}

/// Read-only JSONL store of evidence rows (spec §6.2: writes happen only via
/// the explicit ingest gate, which lands in M4).
public struct EvidenceStore: Sendable {
    public let rows: [EvidenceRow]

    public init(rows: [EvidenceRow]) {
        self.rows = rows
    }

    /// `BESTOCR_EVIDENCE` env override, else `evidence/rows.jsonl` under CWD
    /// (the repo layout; other callers set the env).
    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["BESTOCR_EVIDENCE"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "evidence/rows.jsonl")
    }

    /// Absent file → empty store (the honest evidence-pending path).
    /// A malformed line is an error, not a skip — bad evidence must be loud.
    public static func load(from url: URL) throws -> EvidenceStore {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EvidenceStore(rows: [])
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var rows: [EvidenceRow] = []
        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                rows.append(try decoder.decode(EvidenceRow.self, from: Data(line.utf8)))
            } catch {
                throw OCREngineError(engine: "evidence",
                                     message: "\(url.path):\(index + 1): malformed evidence row — \(error.localizedDescription)")
            }
        }
        return EvidenceStore(rows: rows)
    }

    public func rows(docType: String) -> [EvidenceRow] {
        rows.filter { $0.condition.docType == docType }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EvidenceStoreTests 2>&1 | tail -3`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/Recommend Tests/BestOCRKitTests/EvidenceStoreTests.swift
git commit -m "feat: WorkloadSpec + EvidenceStore (JSONL rows, absent-file = evidence-pending)"
```

---

### Task 5: Recommender (tier discipline)

**Files:**
- Create: `Sources/BestOCRKit/Recommend/Recommender.swift`
- Test: `Tests/BestOCRKitTests/RecommenderTests.swift`

**Interfaces:**
- Consumes: `WorkloadSpec`, `EvidenceStore`, `EngineRegistry`, `StubEngine` (test target).
- Produces: `Recommendation` (`mode: Mode` where `enum Mode: Equatable { case ranked(tier: String); case evidencePending }`, `entries: [Entry]` with `Entry(engineID:String, note:String)`, `citations: [String]`); `Recommender.recommend(workload:WorkloadSpec, registry:EngineRegistry, evidence:EvidenceStore) -> Recommendation`.

- [ ] **Step 1: Write the failing tests**

`Tests/BestOCRKitTests/RecommenderTests.swift`:

```swift
import Testing
@testable import BestOCRKit

struct RecommenderTests {
    static func mathEngine(_ id: String) -> StubEngine {
        StubEngine(id: id, availability: .available, text: "x",
                   outputLevel: .mathMarkdown)
    }

    static func row(model: String, tier: String, estimand: String, value: Double,
                    docType: String = "math_pdf") -> EvidenceRow {
        EvidenceRow(estimand: estimand, value: value,
                    condition: ConditionTuple(model: model, quant: "q8_0", dpi: 100,
                                              docType: docType, platform: "ollama",
                                              hardware: "test", instrument: "test"),
                    tier: tier, source: "test:\(model):\(tier)")
    }

    let registry = EngineRegistry(engines: [
        RecommenderTests.mathEngine("vlm.glm-ocr"),
        RecommenderTests.mathEngine("vlm.ovisocr2"),
        StubEngine(id: "vision", availability: .available, text: "x", outputLevel: .plainText),
    ])

    @Test func noEvidenceYieldsHonestPendingWithCandidates() {
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", needsMath: true),
            registry: registry, evidence: EvidenceStore(rows: []))
        #expect(answer.mode == .evidencePending)
        // Capability filter: needsMath excludes the plain-text engine.
        #expect(answer.entries.map(\.engineID) == ["vlm.glm-ocr", "vlm.ovisocr2"])
        #expect(answer.entries.allSatisfy { $0.note.contains("unverified") })
        #expect(answer.citations.isEmpty)
    }

    @Test func ranksWithinSingleTierAndCites() {
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T2", estimand: "quality.word_recall", value: 0.98),
            Self.row(model: "ovisocr2", tier: "T2", estimand: "quality.word_recall", value: 0.95),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .quality, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.mode == .ranked(tier: "T2"))
        #expect(answer.entries.first?.engineID == "vlm.glm-ocr")   // higher recall first
        #expect(answer.citations.contains("test:glm-ocr:T2"))
    }

    @Test func neverMixesTiersInOneRanking() {
        // glm has T1; ovis has only T2 → ranking is T1-only, ovis is noted, not ranked.
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T1", estimand: "quality.word_recall", value: 0.97),
            Self.row(model: "ovisocr2", tier: "T2", estimand: "quality.word_recall", value: 0.99),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .quality, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.mode == .ranked(tier: "T1"))
        let ranked = answer.entries.filter { !$0.note.contains("not rankable") && !$0.note.contains("unverified") }
        #expect(ranked.map(\.engineID) == ["vlm.glm-ocr"])
        let ovis = answer.entries.first { $0.engineID == "vlm.ovisocr2" }
        #expect(ovis?.note.contains("T2") == true)
        #expect(ovis?.note.contains("not rankable") == true)
    }

    @Test func t3RowsAreNeverRanked() {
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T3", estimand: "quality.word_recall", value: 0.99),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .quality, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.mode == .evidencePending)   // T3 alone never produces a ranking
    }

    @Test func speedPriorityRanksAscending() {
        let evidence = EvidenceStore(rows: [
            Self.row(model: "glm-ocr", tier: "T2", estimand: "speed.ms_per_page", value: 2000),
            Self.row(model: "ovisocr2", tier: "T2", estimand: "speed.ms_per_page", value: 1500),
        ])
        let answer = Recommender.recommend(
            workload: WorkloadSpec(docType: "math_pdf", priority: .speed, needsMath: true),
            registry: registry, evidence: evidence)
        #expect(answer.entries.first?.engineID == "vlm.ovisocr2")   // faster first
    }

    @Test func modelToEngineMatchingHandlesAnovaTags() {
        // Evidence rows say "glm-ocr"; live VLM engines carry "-anova:q8_0" tags.
        #expect(Recommender.baseModel("glm-ocr-anova:q8_0") == "glm-ocr")
        #expect(Recommender.baseModel("glm-ocr") == "glm-ocr")
        #expect(Recommender.baseModel("tesseract") == "tesseract")
    }
}
```

Also extend `StubEngine` in `EngineRegistryTests.swift` with an outputLevel parameter — replace the struct with:

```swift
/// Minimal stub for registry/recommender tests.
struct StubEngine: OCREngine {
    let id: String
    let family = EngineFamily.classical
    let availability: EngineAvailability
    let text: String
    var outputLevel: OutputLevel = .plainText

    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: outputLevel, languages: ["en"],
                           needsNetwork: false, memoryClass: .light)
    }

    func probe() async -> EngineAvailability { availability }

    func recognize(_ request: OCRRequest) async throws -> OCRResult {
        let pages = request.pages.map {
            PageResult(page: $0.pageNumber, text: text, seconds: 0.01,
                       thermalState: "nominal", degenerateFlagged: false)
        }
        let condition = ConditionTuple(model: id, quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "stub",
                                       hardware: "test", instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pages, condition: condition)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RecommenderTests 2>&1 | grep -m1 "error:"`
Expected: FAIL — `cannot find 'Recommender' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/Recommend/Recommender.swift`:

```swift
/// Evidence-disciplined recommendation (spec §6.1; schema.md hard rules):
/// ranking and capability-filtering are different speech acts — the answer
/// always states which one it is.
public struct Recommendation: Sendable {
    public enum Mode: Sendable, Equatable {
        case ranked(tier: String)
        case evidencePending
    }

    public struct Entry: Sendable {
        public let engineID: String
        public let note: String
    }

    public let mode: Mode
    public let entries: [Entry]
    public let citations: [String]
}

public enum Recommender {
    /// "glm-ocr-anova:q8_0" → "glm-ocr": evidence rows name base models; live
    /// engines carry build/quant-suffixed tags.
    static func baseModel(_ model: String) -> String {
        var base = model
        if let colon = base.firstIndex(of: ":") { base = String(base[..<colon]) }
        if base.hasSuffix("-anova") { base = String(base.dropLast("-anova".count)) }
        return base
    }

    /// The model name an engine's rows would carry (mirrors each engine's
    /// ConditionTuple.model), base-normalized.
    static func engineModelKey(_ engine: any OCREngine) -> String {
        if let vlm = engine as? VLMEngine { return baseModel(vlm.resolvedModelTag) }
        if let ext = engine as? ExternalToolEngine { return ext.tool }
        return engine.id   // vision, tesseract, stubs
    }

    static func estimand(for priority: WorkloadSpec.Priority) -> (name: String, higherIsBetter: Bool) {
        switch priority {
        case .quality, .balanced: return ("quality.word_recall", true)
        case .speed: return ("speed.ms_per_page", false)
        }
    }

    public static func recommend(workload: WorkloadSpec, registry: EngineRegistry,
                                 evidence: EvidenceStore) -> Recommendation {
        // 1. Capability filter (never rank what can't do the job).
        let candidates = registry.engines.filter { engine in
            if engine.family == .cloudReference { return false }   // spec §6.1.3
            if workload.needsMath && engine.capabilities.outputLevel != .mathMarkdown { return false }
            if !workload.languages.isEmpty {
                let supported = Set(engine.capabilities.languages)
                if !workload.languages.allSatisfy(supported.contains) { return false }
            }
            return true
        }

        // 2. Rankable rows: matching doc type + the priority's estimand,
        //    T3 excluded (schema.md: never ranked).
        let wanted = estimand(for: workload.priority)
        let matching = evidence.rows(docType: workload.docType)
            .filter { $0.estimand == wanted.name && $0.tier != "T3" }
        let candidateKeys = Set(candidates.map(engineModelKey))
        let usable = matching.filter { candidateKeys.contains(baseModel($0.condition.model)) }

        guard !usable.isEmpty else {
            // 3a. Honest evidence-pending: capability filtering only.
            let entries = candidates.map {
                Recommendation.Entry(engineID: $0.id,
                                     note: "unverified — no measured rows for this workload")
            }
            return Recommendation(mode: .evidencePending, entries: entries, citations: [])
        }

        // 3b. Rank strictly within the highest tier present (T1 > T2).
        let tier = usable.contains { $0.tier == "T1" } ? "T1" : "T2"
        let tierRows = usable.filter { $0.tier == tier }
        var bestByKey: [String: EvidenceRow] = [:]
        for row in tierRows {
            let key = baseModel(row.condition.model)
            if let existing = bestByKey[key] {
                let better = wanted.higherIsBetter ? row.value > existing.value
                                                  : row.value < existing.value
                if better { bestByKey[key] = row }
            } else {
                bestByKey[key] = row
            }
        }

        var ranked: [(engine: any OCREngine, row: EvidenceRow)] = []
        var unranked: [any OCREngine] = []
        for engine in candidates {
            if let row = bestByKey[engineModelKey(engine)] {
                ranked.append((engine, row))
            } else {
                unranked.append(engine)
            }
        }
        ranked.sort {
            wanted.higherIsBetter ? $0.row.value > $1.row.value
                                  : $0.row.value < $1.row.value
        }

        var entries = ranked.map { pair in
            Recommendation.Entry(
                engineID: pair.engine.id,
                note: "\(wanted.name) = \(pair.row.value) (\(tier), \(pair.row.source))"
                    + (pair.row.caveat.map { " — caveat: \($0)" } ?? ""))
        }
        // Other-tier evidence is surfaced but never mixed into the ranking.
        let otherTiers = Dictionary(grouping: usable.filter { $0.tier != tier },
                                    by: { baseModel($0.condition.model) })
        entries += unranked.map { engine in
            let key = engineModelKey(engine)
            if let rows = otherTiers[key], let first = rows.first {
                return Recommendation.Entry(
                    engineID: engine.id,
                    note: "has \(first.tier) evidence — not rankable against \(tier) rows")
            }
            return Recommendation.Entry(engineID: engine.id,
                                        note: "unverified — no measured rows for this workload")
        }
        return Recommendation(mode: .ranked(tier: tier), entries: entries,
                              citations: ranked.map(\.row.source))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RecommenderTests 2>&1 | tail -3`
Expected: PASS — 6 tests. Also run `swift test 2>&1 | tail -1` (StubEngine change touches other suites).
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/Recommend/Recommender.swift Tests/BestOCRKitTests/RecommenderTests.swift Tests/BestOCRKitTests/EngineRegistryTests.swift
git commit -m "feat: Recommender — tier-disciplined ranking with honest evidence-pending mode"
```

---

### Task 6: CLI `recommend` + README M2 status + full verification

**Files:**
- Create: `Sources/bestocr/RecommendCommand.swift`
- Modify: `Sources/bestocr/BestOCRMain.swift` (add subcommand)
- Modify: `README.md` (M2 status, engines list, nougat deferral note)

- [ ] **Step 1: Write the CLI command**

`Sources/bestocr/RecommendCommand.swift`:

```swift
import ArgumentParser
import BestOCRKit
import Foundation

struct Recommend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evidence-labelled engine recommendation for a workload (honest evidence-pending when unmeasured).")

    @Option(name: .customLong("doc-type"),
            help: "Workload doc type matching evidence rows (e.g. math_pdf, scanned_book, screenshot).")
    var docType: String

    @Option(help: "Comma-separated required languages, e.g. \"zh-Hant,en\".")
    var lang: String = ""

    @Option(help: "quality | speed | balanced.")
    var priority: String = "balanced"

    @Flag(help: "Require math-aware output (math_markdown engines only).")
    var math: Bool = false

    mutating func run() async throws {
        guard let prio = WorkloadSpec.Priority(rawValue: priority) else {
            throw ValidationError("--priority must be one of: quality, speed, balanced")
        }
        let languages = lang.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let workload = WorkloadSpec(docType: docType, languages: languages,
                                    priority: prio, needsMath: math)
        let evidence: EvidenceStore
        do {
            evidence = try EvidenceStore.load(from: EvidenceStore.defaultURL())
        } catch let error as OCREngineError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        }
        let answer = Recommender.recommend(workload: workload,
                                           registry: EngineRegistry.standard(),
                                           evidence: evidence)
        switch answer.mode {
        case .ranked(let tier):
            print("RANKED (\(tier) evidence, priority: \(prio.rawValue), doc-type: \(docType))")
        case .evidencePending:
            print("EVIDENCE-PENDING — no measured rows for this workload; this is a capability filter, not a ranking.")
        }
        for (index, entry) in answer.entries.enumerated() {
            print("  \(index + 1). \(entry.engineID) — \(entry.note)")
        }
        if !answer.citations.isEmpty {
            print("evidence rows used: \(answer.citations.joined(separator: "; "))")
        }
    }
}
```

In `BestOCRMain.swift`, change the subcommand list to:

```swift
        subcommands: [Run.self, ListEngines.self, Recommend.self]
```

- [ ] **Step 2: Build and smoke both recommend modes**

```bash
swift build 2>&1 | tail -1
.build/debug/bestocr recommend --doc-type math_pdf --math
```
Expected: `EVIDENCE-PENDING …` + numbered VLM candidates with "unverified" notes (no rows.jsonl exists).

```bash
printf '%s\n' '{"estimand":"quality.word_recall","value":0.98,"condition":{"model":"glm-ocr","quant":"q8_0","dpi":100,"doc_type":"math_pdf","platform":"ollama","hardware":"M5 Max","instrument":"test"},"tier":"T2","source":"smoke-row"}' > /tmp/rows-smoke.jsonl
BESTOCR_EVIDENCE=/tmp/rows-smoke.jsonl .build/debug/bestocr recommend --doc-type math_pdf --math --priority quality
```
Expected: `RANKED (T2 …)` with `vlm.glm-ocr` first, citation `smoke-row`.

- [ ] **Step 3: Update README**

Replace the M1 status paragraph's first two sentences with an M2 version:

```markdown
**Status: M2 — multi-engine + recommend.** `bestocr run` executes any locally
available engine (Apple Vision, tesseract, rapidocr/cnocr/surya via
protocol-v1 Python adapters, Ollama VLMs); `bestocr recommend` returns an
evidence-labelled answer — a tier-named ranking when measured rows exist in
`evidence/rows.jsonl`, otherwise an honest *evidence-pending* capability
filter. Every run records the full evidence condition tuple to
`~/.bestocr/runlog.jsonl`. MCP + plugin land in M3; cloud reference +
`evidence ingest` in M4 (see
`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`).
```

Update the engine-ids paragraph in Usage to:

```markdown
Engine ids: `vision`, `tesseract`, `ext.rapidocr`, `ext.cnocr`, `ext.surya`,
`vlm.glm-ocr`, `vlm.ovisocr2`, `vlm.paddleocr-vl` (VLM engines need a running
`ollama serve`; defaults are the SHA256-pinned `-anova:q8_0` builds, `--model`
overrides). nougat is deferred: its local install is stranded in a pipx venv
and upstream is archived — the adapter protocol makes re-admission a
script-drop when wanted.
```

And add a recommend example to the Usage block:

```bash
.build/release/bestocr recommend --doc-type math_pdf --math --priority quality
```

- [ ] **Step 4: Full verification**

```bash
swift test 2>&1 | tail -1        # ALL PASS
swift build -c release 2>&1 | tail -1
.build/release/bestocr list-engines
```
Expected: tests pass; 8-row probe table.

- [ ] **Step 5: Commit**

```bash
git add Sources/bestocr README.md
git commit -m "feat: bestocr recommend CLI + README M2 status"
```

---

## Plan Self-Review (done at authoring time)

- **Spec coverage (M2 slice)**: adapters (spec §5.4 external row, §8 containment) → T1–T3; recommend §6.1 behaviours 1–2 (ranked-with-tier-and-citations / evidence-pending capability filter) → T4–T6; §6.1.3 cloud exclusion → Recommender filter (guard for M4). Deliberately out: auto-route in `run` (needs recommend+run wiring — start of M3 work), fallback chain, MCP, cloud engines, `evidence ingest` (M4). nougat deferred with documented reason (Global Constraints + README).
- **Placeholder scan**: none — full scripts, Swift, commands, expected outputs.
- **Type consistency**: `ExternalToolEngine(tool:capabilities:installHint:python:script:timeout:)` used identically in T1–T3; `EvidenceRow(estimand:value:condition:tier:source:caveat:)` in T4–T6; `StubEngine` gains `outputLevel` with a default so T7/T9 M1 call sites compile unchanged; `Recommendation.Mode` Equatable for `#expect`.
