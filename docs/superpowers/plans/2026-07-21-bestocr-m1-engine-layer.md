# bestOCR M1 — Engine Layer + CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `BestOCRKit` (OCREngine protocol + VisionEngine + TesseractEngine + VLMEngine/Ollama) and the `bestocr` CLI with `run` and `list-engines`, per spec `docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md` §5, §7-Flow-B, §8, §9, milestone M1.

**Architecture:** A Swift package at the repo root. `BestOCRKit` is the engine library (protocol + three engine families + input normalizer + run log + pipeline); `bestocr` is a thin ArgumentParser shell. PDFs are always rendered to page images first (spec §5.2); every result carries the evidence-schema condition tuple (spec §5.3).

**Tech Stack:** Swift 6.1 tools / macOS 14+, Swift Testing (`import Testing`), swift-argument-parser, `OCRCore` (PsychQuant/ocr-swift ≥0.2.1, Ollama backend), `PDFToLaTeXCore` (PsychQuant/pdf-to-latex-swift ≥0.1.0, PageRenderer), Vision framework, tesseract via subprocess.

## Global Constraints

- Package: `swift-tools-version: 6.1`, `platforms: [.macOS(.v14)]`; products `bestocr` (executable) + `BestOCRKit` (library). Dependencies exactly: `swift-argument-parser from: "1.3.0"`, `ocr-swift from: "0.2.1"`, `pdf-to-latex-swift from: "0.1.0"`.
- Test framework is Swift Testing (`import Testing`, `@Test`, `#expect`) — NOT XCTest.
- **Never modify anything under `repos/measureOCR/`** (article-1 frozen instrument).
- Engines only ever see page images (spec §5.2). No engine parses PDFs itself.
- Condition-tuple JSON keys must match `evidence/schema.md` §3 exactly: `model, quant, dpi, doc_type, platform, hardware, instrument`.
- No cloud engines, no `recommend`, no auto-routing, no MCP in M1 (spec M2–M4).
- Probe before dispatch; unavailable → clear reason + install hint (spec §8). Never silently swallow errors.
- Immutability: value types (`struct`/`enum`), `let` over `var`.
- Commit after every task (conventional commits: `feat:`/`test:`/`chore:`). No attribution footer. Never place `fix`/`close`/`resolve` adjacent to `#N` in a commit message.
- Run all commands from repo root `/Users/che/Developer/bestOCR`.
- `VNRecognizeTextRequest` deprecation warnings under the current SDK are acceptable in M1 (the macOS-14 platform floor rules out the newer struct-based Vision API).

---

### Task 1: Package scaffold + core types

**Files:**
- Create: `Package.swift`
- Create: `Sources/BestOCRKit/CoreTypes.swift`
- Create: `Sources/BestOCRKit/OCRModels.swift`
- Create: `Sources/BestOCRKit/HostInfo.swift`
- Create: `Sources/bestocr/BestOCRMain.swift` (placeholder so the executable target builds)
- Modify: `.gitignore` (append build artifacts)
- Test: `Tests/BestOCRKitTests/CoreTypesTests.swift`

**Interfaces:**
- Produces: `EngineFamily` (`.localVLM/.classical/.cloudReference`), `OutputLevel` (`.plainText/.markdown/.mathMarkdown`), `MemoryClass` (`.light/.medium/.heavy`), `EngineAvailability` (`.available` / `.unavailable(reason:String, installHint:String?)`), `EngineCapabilities`, `OCREngineError(engine:message:)`, `BestOCRVersion.string`, `OCREngine` protocol, `PageImage(pageNumber:Int, url:URL)`, `OCRRequest(pages:[PageImage], languages:[String], dpi:Double?, docType:String)`, `PageResult(page:Int, text:String, seconds:Double, thermalState:String, degenerateFlagged:Bool)`, `ConditionTuple(model:quant:dpi:docType:platform:hardware:instrument:)`, `OCRResult(engineID:pages:condition:)` with computed `text`, `HostInfo.hardwareLabel()`, `HostInfo.thermalLabel()`.

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/CoreTypesTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct CoreTypesTests {
    @Test func conditionTupleEncodesSchemaKeys() throws {
        let tuple = ConditionTuple(
            model: "glm-ocr", quant: "q4_K_M", dpi: 150,
            docType: "math_compiled", platform: "ollama",
            hardware: "Apple M5 Max, 128GB", instrument: BestOCRVersion.string
        )
        let data = try JSONEncoder().encode(tuple)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Keys must match evidence/schema.md §3 verbatim.
        #expect(Set(json.keys) == ["model", "quant", "dpi", "doc_type", "platform", "hardware", "instrument"])
        #expect(json["doc_type"] as? String == "math_compiled")
    }

    @Test func ocrResultJoinsPageText() {
        let condition = ConditionTuple(
            model: "vision", quant: "n/a", dpi: nil, docType: "unspecified",
            platform: "vision", hardware: "test", instrument: BestOCRVersion.string
        )
        let result = OCRResult(engineID: "vision", pages: [
            PageResult(page: 1, text: "one", seconds: 0.1, thermalState: "nominal", degenerateFlagged: false),
            PageResult(page: 2, text: "two", seconds: 0.1, thermalState: "nominal", degenerateFlagged: false),
        ], condition: condition)
        #expect(result.text == "one\n\ntwo")
    }

    @Test func hardwareLabelMentionsAppleAndMemory() {
        let label = HostInfo.hardwareLabel()
        #expect(label.contains("Apple"))
        #expect(label.contains("GB"))
    }
}
```

- [ ] **Step 2: Create Package.swift and run test to verify it fails**

`Package.swift`:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "bestocr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bestocr", targets: ["bestocr"]),
        .library(name: "BestOCRKit", targets: ["BestOCRKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/PsychQuant/ocr-swift.git", from: "0.2.1"),
        .package(url: "https://github.com/PsychQuant/pdf-to-latex-swift.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "BestOCRKit",
            dependencies: [
                .product(name: "OCRCore", package: "ocr-swift"),
                .product(name: "PDFToLaTeXCore", package: "pdf-to-latex-swift"),
            ]
        ),
        .executableTarget(
            name: "bestocr",
            dependencies: [
                "BestOCRKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BestOCRKitTests", dependencies: ["BestOCRKit"]),
    ]
)
```

`Sources/bestocr/BestOCRMain.swift` (placeholder, replaced in Task 9):

```swift
@main
struct BestOCRPlaceholder {
    static func main() { print("bestocr M1 — CLI lands in Task 9") }
}
```

Append to `.gitignore`:

```
.build/
Package.resolved
```

Run: `swift test --filter CoreTypesTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ConditionTuple' in scope` (compile error is the RED state).

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/CoreTypes.swift`:

```swift
import Foundation

/// bestOCR product version string, recorded as the `instrument` field of every
/// condition tuple (evidence/schema.md §3) until git-sha stamping arrives.
public enum BestOCRVersion {
    public static let string = "bestocr 0.1.0-dev"
}

/// Spec §5.1 — engine families. Cloud stays reference-only (spec §6.1.3).
public enum EngineFamily: String, Sendable, Codable {
    case localVLM = "local_vlm"
    case classical
    case cloudReference = "cloud_reference"
}

/// What fidelity of output an engine can produce.
public enum OutputLevel: String, Sendable, Codable {
    case plainText = "plain_text"
    case markdown
    case mathMarkdown = "math_markdown"
}

/// Rough unified-memory footprint class, for capability display and later filtering.
public enum MemoryClass: String, Sendable, Codable {
    case light      // <500 MB (Vision, tesseract)
    case medium     // 0.5–4 GB (0.9B-class VLM quants)
    case heavy      // >4 GB
}

/// Spec §5.1/§8 — probe result. Absence is a value, never an exception.
public enum EngineAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String, installHint: String?)
}

/// Spec §5.1 — declared capabilities used for display (M1) and filtering (M2).
public struct EngineCapabilities: Sendable {
    public let outputLevel: OutputLevel
    public let languages: [String]      // BCP-47-style: "en", "zh-Hant", "zh-Hans", "ja"
    public let needsNetwork: Bool
    public let memoryClass: MemoryClass

    public init(outputLevel: OutputLevel, languages: [String], needsNetwork: Bool, memoryClass: MemoryClass) {
        self.outputLevel = outputLevel
        self.languages = languages
        self.needsNetwork = needsNetwork
        self.memoryClass = memoryClass
    }
}

/// Spec §8 — every engine failure surfaces engine id + reason (never silent).
public struct OCREngineError: Error, LocalizedError {
    public let engine: String
    public let message: String

    public init(engine: String, message: String) {
        self.engine = engine
        self.message = message
    }

    public var errorDescription: String? { "[\(engine)] \(message)" }
}

/// Spec §5.1 — the common contract every OCR engine implements.
public protocol OCREngine: Sendable {
    var id: String { get }
    var family: EngineFamily { get }
    var capabilities: EngineCapabilities { get }
    /// Probes lazily and never throws — absence is reported as a value.
    func probe() async -> EngineAvailability
    func recognize(_ request: OCRRequest) async throws -> OCRResult
}
```

`Sources/BestOCRKit/OCRModels.swift`:

```swift
import Foundation

/// A single normalized page image (spec §5.2: engines only ever see these).
public struct PageImage: Sendable {
    public let pageNumber: Int
    public let url: URL

    public init(pageNumber: Int, url: URL) {
        self.pageNumber = pageNumber
        self.url = url
    }
}

/// Input to `OCREngine.recognize` after normalization.
public struct OCRRequest: Sendable {
    public let pages: [PageImage]
    public let languages: [String]   // preference; engines map to their own codes
    public let dpi: Double?          // render DPI; nil when input was a raw image
    public let docType: String       // caller-declared workload label for the condition tuple

    public init(pages: [PageImage], languages: [String] = [], dpi: Double? = nil, docType: String = "unspecified") {
        self.pages = pages
        self.languages = languages
        self.dpi = dpi
        self.docType = docType
    }
}

/// Per-page output with provenance (spec §5.3).
public struct PageResult: Sendable, Codable {
    public let page: Int
    public let text: String
    public let seconds: Double
    public let thermalState: String
    public let degenerateFlagged: Bool

    public init(page: Int, text: String, seconds: Double, thermalState: String, degenerateFlagged: Bool) {
        self.page = page
        self.text = text
        self.seconds = seconds
        self.thermalState = thermalState
        self.degenerateFlagged = degenerateFlagged
    }
}

/// evidence/schema.md §3 — full condition tuple; JSON keys match verbatim.
public struct ConditionTuple: Sendable, Codable {
    public let model: String
    public let quant: String       // "n/a" for non-quantised engines
    public let dpi: Double?
    public let docType: String
    public let platform: String    // "vision" / "tesseract" / "ollama"
    public let hardware: String
    public let instrument: String

    enum CodingKeys: String, CodingKey {
        case model, quant, dpi, platform, hardware, instrument
        case docType = "doc_type"
    }

    public init(model: String, quant: String, dpi: Double?, docType: String,
                platform: String, hardware: String, instrument: String) {
        self.model = model
        self.quant = quant
        self.dpi = dpi
        self.docType = docType
        self.platform = platform
        self.hardware = hardware
        self.instrument = instrument
    }
}

/// Unified engine output (spec §5.3): pages + condition tuple.
public struct OCRResult: Sendable, Codable {
    public let engineID: String
    public let pages: [PageResult]
    public let condition: ConditionTuple

    public init(engineID: String, pages: [PageResult], condition: ConditionTuple) {
        self.engineID = engineID
        self.pages = pages
        self.condition = condition
    }

    /// All page text joined; not encoded (derived).
    public var text: String { pages.map(\.text).joined(separator: "\n\n") }
}
```

`Sources/BestOCRKit/HostInfo.swift`:

```swift
import Foundation

/// Host provenance helpers for the condition tuple (spec §5.3).
public enum HostInfo {
    /// e.g. "Apple M5 Max, 128GB" — CPU brand via sysctl + physical memory.
    public static func hardwareLabel() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        let brand = String(cString: chars)
        let gb = ProcessInfo.processInfo.physicalMemory / (1 << 30)
        return "\(brand), \(gb)GB"
    }

    /// Current thermal state as the evidence-schema label (hard rule 5).
    public static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CoreTypesTests 2>&1 | tail -5`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources .gitignore Tests
git commit -m "feat: BestOCRKit package scaffold — OCREngine protocol + condition-tuple core types"
```

---

### Task 2: RepetitionGuard (degenerate-loop fuse)

**Files:**
- Create: `Sources/BestOCRKit/RepetitionGuard.swift`
- Test: `Tests/BestOCRKitTests/RepetitionGuardTests.swift`

**Interfaces:**
- Produces: `RepetitionGuard(maxCharRun: Int = 200, maxTokenRepeat: Int = 50)` with `func flags(_ text: String) -> Bool`. Used by `VLMEngine` (Task 6).

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/RepetitionGuardTests.swift`:

```swift
import Testing
@testable import BestOCRKit

struct RepetitionGuardTests {
    let fuse = RepetitionGuard()

    @Test func normalTextDoesNotFlag() {
        #expect(!fuse.flags("A normal page of prose with $x^2$ math and 標題 headings."))
    }

    @Test func longIdenticalCharRunFlags() {
        #expect(fuse.flags("prefix " + String(repeating: "!", count: 200) + " suffix"))
    }

    @Test func charRunBelowThresholdDoesNotFlag() {
        #expect(!fuse.flags(String(repeating: "!", count: 199)))
    }

    @Test func repeatedTokenLoopFlags() {
        // PaddleOCR-VL-style degenerate loop: same token repeated endlessly.
        let loop = Array(repeating: "the", count: 50).joined(separator: " ")
        #expect(fuse.flags(loop))
    }

    @Test func repeatedTokenBelowThresholdDoesNotFlag() {
        let ok = Array(repeating: "the", count: 49).joined(separator: " ")
        #expect(!fuse.flags(ok))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RepetitionGuardTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'RepetitionGuard' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/RepetitionGuard.swift`:

```swift
/// Degenerate-generation fuse (spec §8): flags VLM output that has collapsed
/// into a repetition loop (e.g. PaddleOCR-VL under a non-native prompt).
/// Mirrors the instrument's guard thresholds (measureOCR maxRunLength 200)
/// without depending on the frozen instrument.
public struct RepetitionGuard: Sendable {
    public let maxCharRun: Int
    public let maxTokenRepeat: Int

    public init(maxCharRun: Int = 200, maxTokenRepeat: Int = 50) {
        self.maxCharRun = maxCharRun
        self.maxTokenRepeat = maxTokenRepeat
    }

    public func flags(_ text: String) -> Bool {
        // Run of identical characters.
        var runChar: Character? = nil
        var runLength = 0
        for ch in text {
            if ch == runChar {
                runLength += 1
                if runLength >= maxCharRun { return true }
            } else {
                runChar = ch
                runLength = 1
            }
        }
        // Run of identical whitespace-separated tokens.
        var runToken: Substring? = nil
        var tokenCount = 0
        for token in text.split(whereSeparator: \.isWhitespace) {
            if token == runToken {
                tokenCount += 1
                if tokenCount >= maxTokenRepeat { return true }
            } else {
                runToken = token
                tokenCount = 1
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RepetitionGuardTests 2>&1 | tail -5`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/RepetitionGuard.swift Tests/BestOCRKitTests/RepetitionGuardTests.swift
git commit -m "feat: RepetitionGuard degenerate-loop fuse for VLM output"
```

---

### Task 3: Test fixtures + InputNormalizer (PDF → page images)

**Files:**
- Create: `Tests/BestOCRKitTests/Fixtures.swift`
- Create: `Sources/BestOCRKit/InputNormalizer.swift`
- Test: `Tests/BestOCRKitTests/InputNormalizerTests.swift`

**Interfaces:**
- Consumes: `PageImage` (Task 1); `PageRenderer` / `RenderedPage(pageNumber:imagePath:)` from `PDFToLaTeXCore`.
- Produces: `NormalizedInput(pages:[PageImage], dpi:Double?, cleanupDir:URL?)` with `func cleanup()`; `InputNormalizer.normalize(inputPath:String, dpi:Double, pageSpec:String, workDir:URL?) throws -> NormalizedInput`; `InputNormalizer.parsePages(_ spec:String, count:Int) -> [Int]`. Test helpers `Fixtures.textImage(_ text:String) throws -> URL` and `Fixtures.textPDF(_ text:String, pages:Int) throws -> URL` (used by Tasks 4, 5, 9).

- [ ] **Step 1: Write the fixture helpers**

`Tests/BestOCRKitTests/Fixtures.swift`:

```swift
import AppKit
import Foundation

/// Programmatic fixtures — no binary files in git. Big clean type so Vision
/// and tesseract recognize deterministically.
enum Fixtures {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bestocr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 800×200 white PNG with `text` drawn in 72 pt black bold.
    static func textImage(_ text: String) throws -> URL {
        let size = NSSize(width: 800, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(
                at: NSPoint(x: 40, y: 60),
                withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 72),
                    .foregroundColor: NSColor.black,
                ]
            )
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Fixtures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        let url = try tempDir().appendingPathComponent("fixture.png")
        try png.write(to: url)
        return url
    }

    /// US-letter PDF with `pages` pages, each showing `text` + page number in 48 pt.
    static func textPDF(_ text: String, pages: Int) throws -> URL {
        let url = try tempDir().appendingPathComponent("fixture.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "Fixtures", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PDF context failed"])
        }
        for page in 1...pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(
                string: "\(text) page \(page)",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 48),
                             .foregroundColor: NSColor.black]
            )
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 72, y: 400)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
```

- [ ] **Step 2: Write the failing normalizer test**

`Tests/BestOCRKitTests/InputNormalizerTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct InputNormalizerTests {
    @Test func parsePagesHandlesRangesAndSingles() {
        #expect(InputNormalizer.parsePages("1-3,5", count: 10) == [1, 2, 3, 5])
        #expect(InputNormalizer.parsePages("", count: 3) == [1, 2, 3])
        #expect(InputNormalizer.parsePages("2-99", count: 4) == [2, 3, 4])
        #expect(InputNormalizer.parsePages("7", count: 4) == [])
    }

    @Test func imagePassesThroughWithNilDPI() throws {
        let img = try Fixtures.textImage("HELLO 42")
        let normalized = try InputNormalizer.normalize(
            inputPath: img.path, dpi: 150, pageSpec: "", workDir: nil)
        defer { normalized.cleanup() }
        #expect(normalized.pages.count == 1)
        #expect(normalized.pages[0].pageNumber == 1)
        #expect(normalized.pages[0].url == img)
        #expect(normalized.dpi == nil)
        #expect(normalized.cleanupDir == nil)
    }

    @Test func pdfRendersRequestedPagesAtDPI() throws {
        let pdf = try Fixtures.textPDF("NORMALIZE", pages: 3)
        let normalized = try InputNormalizer.normalize(
            inputPath: pdf.path, dpi: 100, pageSpec: "1-2", workDir: nil)
        defer { normalized.cleanup() }
        #expect(normalized.pages.count == 2)
        #expect(normalized.pages.map(\.pageNumber) == [1, 2])
        #expect(normalized.dpi == 100)
        for page in normalized.pages {
            #expect(FileManager.default.fileExists(atPath: page.url.path))
        }
        let dir = try #require(normalized.cleanupDir)
        normalized.cleanup()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func unknownExtensionThrows() {
        #expect(throws: OCREngineError.self) {
            _ = try InputNormalizer.normalize(
                inputPath: "/tmp/nope.docx", dpi: 150, pageSpec: "", workDir: nil)
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter InputNormalizerTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'InputNormalizer' in scope`.

- [ ] **Step 4: Write minimal implementation**

`Sources/BestOCRKit/InputNormalizer.swift`:

```swift
import Foundation
import PDFKit
import PDFToLaTeXCore

/// Normalized input: the page-image sequence every engine consumes (spec §5.2).
public struct NormalizedInput: Sendable {
    public let pages: [PageImage]
    public let dpi: Double?       // render DPI; nil for raw-image passthrough
    public let cleanupDir: URL?   // temp render dir to delete after use

    public func cleanup() {
        guard let cleanupDir else { return }
        try? FileManager.default.removeItem(at: cleanupDir)
    }
}

/// PDF → page images via PageRenderer; raw images pass through (spec §5.2).
public enum InputNormalizer {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "bmp"]

    /// Page-spec parser, ported from the instrument (measureOCR OCRLoop.swift)
    /// so `--pages 1-3,7` behaves identically across product and instrument.
    public static func parsePages(_ spec: String, count: Int) -> [Int] {
        let all = Array(1...max(count, 1))
        if spec.isEmpty { return all }
        var out: [Int] = []
        for part in spec.split(separator: ",") {
            if let dash = part.firstIndex(of: "-") {
                let rawA = Int(part[part.startIndex..<dash]) ?? 1
                let rawB = Int(part[part.index(after: dash)...]) ?? rawA
                let a = min(max(rawA, 1), count)
                let b = min(max(rawB, 1), count)
                out.append(contentsOf: a...max(a, b))
            } else if let n = Int(part) {
                out.append(n)
            }
        }
        return out.filter { $0 >= 1 && $0 <= count }
    }

    /// Contiguous (first, last) runs so the renderer is invoked once per run.
    static func contiguousRuns(_ pages: [Int]) -> [(first: Int, last: Int)] {
        let sorted = Array(Set(pages)).sorted()
        var runs: [(first: Int, last: Int)] = []
        for p in sorted {
            if let last = runs.last, p == last.last + 1 {
                runs[runs.count - 1].last = p
            } else {
                runs.append((first: p, last: p))
            }
        }
        return runs
    }

    public static func normalize(inputPath: String, dpi: Double, pageSpec: String,
                                 workDir: URL?) throws -> NormalizedInput {
        let url = URL(fileURLWithPath: inputPath)
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return NormalizedInput(pages: [PageImage(pageNumber: 1, url: url)],
                                   dpi: nil, cleanupDir: nil)
        }
        guard ext == "pdf" else {
            throw OCREngineError(engine: "normalizer",
                                 message: "unsupported input type .\(ext) — expected pdf or image (\(imageExtensions.sorted().joined(separator: "/")))")
        }
        guard let document = PDFDocument(url: url) else {
            throw OCREngineError(engine: "normalizer", message: "cannot open PDF: \(inputPath)")
        }
        let wanted = parsePages(pageSpec, count: document.pageCount)
        guard !wanted.isEmpty else {
            throw OCREngineError(engine: "normalizer",
                                 message: "page spec '\(pageSpec)' selects no pages (document has \(document.pageCount))")
        }
        let renderDir = workDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("bestocr-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
        let renderer = PageRenderer()
        var byPage: [Int: String] = [:]
        for run in contiguousRuns(wanted) {
            let rendered = try renderer.renderPages(
                pdfAt: url, outputDirectory: renderDir, dpi: dpi,
                firstPage: run.first, lastPage: run.last)
            for r in rendered { byPage[r.pageNumber] = r.imagePath }
        }
        let pages = wanted.compactMap { n in
            byPage[n].map { PageImage(pageNumber: n, url: URL(fileURLWithPath: $0)) }
        }
        return NormalizedInput(pages: pages, dpi: dpi, cleanupDir: renderDir)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter InputNormalizerTests 2>&1 | tail -5`
Expected: PASS — 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/BestOCRKit/InputNormalizer.swift Tests/BestOCRKitTests/Fixtures.swift Tests/BestOCRKitTests/InputNormalizerTests.swift
git commit -m "feat: InputNormalizer — PDF-to-page-image seam + programmatic test fixtures"
```

---

### Task 4: VisionEngine (Apple Vision framework)

**Files:**
- Create: `Sources/BestOCRKit/Engines/VisionEngine.swift`
- Test: `Tests/BestOCRKitTests/VisionEngineTests.swift`

**Interfaces:**
- Consumes: `OCREngine`, `OCRRequest`, `OCRResult`, `PageResult`, `ConditionTuple`, `HostInfo`, `OCREngineError` (Task 1); `Fixtures.textImage` (Task 3).
- Produces: `VisionEngine()` — `id == "vision"`, `family == .classical`, always `.available`.

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/VisionEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct VisionEngineTests {
    let engine = VisionEngine()

    @Test func identityAndCapabilities() {
        #expect(engine.id == "vision")
        #expect(engine.family == .classical)
        #expect(engine.capabilities.needsNetwork == false)
        #expect(engine.capabilities.outputLevel == .plainText)
    }

    @Test func probeIsAlwaysAvailable() async {
        #expect(await engine.probe() == .available)
    }

    @Test func recognizesFixtureText() async throws {
        let img = try Fixtures.textImage("HELLO 42")
        let request = OCRRequest(pages: [PageImage(pageNumber: 1, url: img)],
                                 languages: ["en"], dpi: nil, docType: "screenshot")
        let result = try await engine.recognize(request)
        #expect(result.engineID == "vision")
        #expect(result.pages.count == 1)
        #expect(result.pages[0].text.contains("HELLO"))
        #expect(result.condition.model == "vision")
        #expect(result.condition.quant == "n/a")
        #expect(result.condition.docType == "screenshot")
        #expect(result.pages[0].seconds > 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VisionEngineTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'VisionEngine' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/Engines/VisionEngine.swift`:

```swift
import Foundation
import Vision

/// Apple Vision framework engine — in-process, zero-dependency, always
/// available on macOS (spec §5.4: screenshots, quick single images, zh-Hant/ja).
/// Uses VNRecognizeTextRequest for the macOS-14 floor; deprecation warnings
/// under newer SDKs are accepted for M1.
public struct VisionEngine: OCREngine {
    public let id = "vision"
    public let family = EngineFamily.classical

    public var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText,
                           languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                           needsNetwork: false,
                           memoryClass: .light)
    }

    public init() {}

    public func probe() async -> EngineAvailability {
        .available   // OS framework — present on every supported macOS
    }

    /// Map request languages to Vision codes; default favours the user's
    /// zh-Hant/ja/en daily mix.
    static func visionLanguages(_ languages: [String]) -> [String] {
        guard !languages.isEmpty else { return ["zh-Hant", "ja", "en-US"] }
        return languages.map { $0 == "en" ? "en-US" : $0 }
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        var pageResults: [PageResult] = []
        for page in request.pages {
            let t0 = ProcessInfo.processInfo.systemUptime
            let vnRequest = VNRecognizeTextRequest()
            vnRequest.recognitionLevel = .accurate
            vnRequest.usesLanguageCorrection = true
            vnRequest.recognitionLanguages = Self.visionLanguages(request.languages)
            let handler = VNImageRequestHandler(url: page.url)
            do {
                try handler.perform([vnRequest])
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            let text = (vnRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            pageResults.append(PageResult(page: page.pageNumber, text: text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: "vision", quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "vision",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VisionEngineTests 2>&1 | tail -5`
Expected: PASS — 3 tests (fixture text "HELLO" recognized).

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/Engines/VisionEngine.swift Tests/BestOCRKitTests/VisionEngineTests.swift
git commit -m "feat: VisionEngine — Apple Vision classical engine, always-available"
```

---

### Task 5: Subprocess helper + TesseractEngine

**Files:**
- Create: `Sources/BestOCRKit/Engines/Subprocess.swift`
- Create: `Sources/BestOCRKit/Engines/TesseractEngine.swift`
- Test: `Tests/BestOCRKitTests/TesseractEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `Fixtures.textImage` (Task 3).
- Produces: `Subprocess.run(_ executable:URL, arguments:[String], timeout:TimeInterval) throws -> Subprocess.Result` (`stdout/stderr/exitCode`); `TesseractEngine(binaryPath:String?)` — `id == "tesseract"`, `TesseractEngine.locate() -> URL?`, `TesseractEngine.tesseractLanguages(_:[String]) -> String`.

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/TesseractEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct TesseractEngineTests {
    @Test func identity() {
        let engine = TesseractEngine()
        #expect(engine.id == "tesseract")
        #expect(engine.family == .classical)
        #expect(engine.capabilities.needsNetwork == false)
    }

    @Test func languageMapping() {
        #expect(TesseractEngine.tesseractLanguages(["en"]) == "eng")
        #expect(TesseractEngine.tesseractLanguages(["zh-Hant", "ja"]) == "chi_tra+jpn")
        #expect(TesseractEngine.tesseractLanguages([]) == "eng")
        #expect(TesseractEngine.tesseractLanguages(["xx"]) == "eng")   // unknown → fallback
    }

    @Test func missingBinaryProbesUnavailableWithHint() async {
        let engine = TesseractEngine(binaryPath: "/nonexistent/tesseract")
        let availability = await engine.probe()
        guard case .unavailable(let reason, let hint) = availability else {
            Issue.record("expected unavailable, got \(availability)")
            return
        }
        #expect(reason.contains("tesseract"))
        #expect(hint == "brew install tesseract tesseract-lang")
    }

    // Integration: runs only when tesseract is actually installed (spec §9:
    // absent tool → visible skip, never fake-pass).
    @Test(.enabled(if: TesseractEngine.locate() != nil))
    func recognizesFixtureText() async throws {
        let engine = TesseractEngine()
        let img = try Fixtures.textImage("HELLO 42")
        let request = OCRRequest(pages: [PageImage(pageNumber: 1, url: img)],
                                 languages: ["en"], dpi: nil, docType: "screenshot")
        let result = try await engine.recognize(request)
        #expect(result.pages[0].text.contains("HELLO"))
        #expect(result.condition.platform == "tesseract")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TesseractEngineTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'TesseractEngine' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/Engines/Subprocess.swift`:

```swift
import Foundation

/// Minimal subprocess runner with timeout — the shared mechanism for CLI-tool
/// engines (tesseract now; external protocol-v1 adapters in M2).
public enum Subprocess {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    public struct TimeoutError: Error, LocalizedError {
        public let seconds: TimeInterval
        public var errorDescription: String? { "process timed out after \(Int(seconds))s" }
    }

    /// NSLock-guarded byte box so pipe reads satisfy strict concurrency.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    public static func run(_ executable: URL, arguments: [String],
                           timeout: TimeInterval = 120) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = DataBox(), errBox = DataBox()
        let readGroup = DispatchGroup()
        // Drain both pipes concurrently so a chatty child never deadlocks on
        // a full pipe buffer before we observe termination.
        readGroup.enter()
        DispatchQueue.global().async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TimeoutError(seconds: timeout)
        }
        readGroup.wait()
        return Result(stdout: String(data: outBox.get(), encoding: .utf8) ?? "",
                      stderr: String(data: errBox.get(), encoding: .utf8) ?? "",
                      exitCode: process.terminationStatus)
    }
}
```

`Sources/BestOCRKit/Engines/TesseractEngine.swift`:

```swift
import Foundation

/// Classical OCR via the tesseract CLI (spec §5.4: scanned-book batches,
/// low memory). Integrated as a subprocess; probe reports the install hint.
public struct TesseractEngine: OCREngine {
    public let id = "tesseract"
    public let family = EngineFamily.classical
    let binaryPath: String?

    public var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText,
                           languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                           needsNetwork: false,
                           memoryClass: .light)
    }

    /// Pass `binaryPath` explicitly in tests; nil = search standard locations.
    public init(binaryPath: String? = nil) {
        self.binaryPath = binaryPath
    }

    /// Standard Homebrew / MacPorts / manual locations, then PATH.
    public static func locate() -> URL? {
        let candidates = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let path = "\(dir)/tesseract"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func resolvedBinary() -> URL? {
        if let binaryPath {
            return FileManager.default.isExecutableFile(atPath: binaryPath)
                ? URL(fileURLWithPath: binaryPath) : nil
        }
        return Self.locate()
    }

    /// BCP-47-ish → tesseract language codes; unknown codes fall back to eng.
    static func tesseractLanguages(_ languages: [String]) -> String {
        let map = ["en": "eng", "zh-Hant": "chi_tra", "zh-Hans": "chi_sim", "ja": "jpn"]
        let codes = languages.compactMap { map[$0] }
        return codes.isEmpty ? "eng" : codes.joined(separator: "+")
    }

    public func probe() async -> EngineAvailability {
        guard resolvedBinary() != nil else {
            return .unavailable(reason: "tesseract binary not found",
                                installHint: "brew install tesseract tesseract-lang")
        }
        return .available
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        guard let binary = resolvedBinary() else {
            throw OCREngineError(engine: id,
                                 message: "tesseract binary not found — brew install tesseract tesseract-lang")
        }
        let langs = Self.tesseractLanguages(request.languages)
        var pageResults: [PageResult] = []
        for page in request.pages {
            let t0 = ProcessInfo.processInfo.systemUptime
            let run: Subprocess.Result
            do {
                run = try Subprocess.run(binary, arguments: [page.url.path, "stdout", "-l", langs])
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            guard run.exitCode == 0 else {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): exit \(run.exitCode): \(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            pageResults.append(PageResult(page: page.pageNumber,
                                          text: run.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: "tesseract", quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "tesseract",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TesseractEngineTests 2>&1 | tail -5`
Expected: PASS — 4 tests (integration test runs because tesseract is installed at `/opt/homebrew/bin/tesseract`; on machines without it, it shows as skipped).

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/Engines/Subprocess.swift Sources/BestOCRKit/Engines/TesseractEngine.swift Tests/BestOCRKitTests/TesseractEngineTests.swift
git commit -m "feat: TesseractEngine via subprocess + shared timeout-safe Subprocess runner"
```

---

### Task 6: ModelProfile + VLMEngine (Ollama)

**Files:**
- Create: `Sources/BestOCRKit/Engines/ModelProfile.swift`
- Create: `Sources/BestOCRKit/Engines/VLMEngine.swift`
- Test: `Tests/BestOCRKitTests/VLMEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `RepetitionGuard` (Task 2); `OllamaBackend(host:model:prompt:numCtx:maxTokens:)` + `processImage(_ imageData: Data) async throws -> String` from `OCRCore`.
- Produces: `ModelProfile(id:ollamaModel:prompt:outputLevel:)` with statics `.glmOCR`, `.ovisOCR2`, `.paddleOCRVL` and `ModelProfile.all`; `VLMEngine(profile:host:modelOverride:)` — `id == "vlm.<profile.id>"`.

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/VLMEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct VLMEngineTests {
    @Test func profileRosterCoversAdmittedCandidates() {
        let ids = ModelProfile.all.map(\.id)
        #expect(ids == ["glm-ocr", "ovisocr2", "paddleocr-vl"])
    }

    @Test func paddleUsesNativeTaskPrompt() {
        // candidates.json caveat: generic instruction prompts yield degenerate
        // loops — the native task prompt is mandatory for PaddleOCR-VL.
        #expect(ModelProfile.paddleOCRVL.prompt == "OCR:")
    }

    @Test func glmAndOvisUseSharedInstructionPrompt() {
        #expect(ModelProfile.glmOCR.prompt == ModelProfile.sharedInstructionPrompt)
        #expect(ModelProfile.ovisOCR2.prompt == ModelProfile.sharedInstructionPrompt)
        #expect(ModelProfile.sharedInstructionPrompt.contains("Markdown"))
    }

    @Test func engineIdentityAndCapabilities() {
        let engine = VLMEngine(profile: .glmOCR)
        #expect(engine.id == "vlm.glm-ocr")
        #expect(engine.family == .localVLM)
        #expect(engine.capabilities.outputLevel == .mathMarkdown)
        #expect(engine.capabilities.needsNetwork == false)   // localhost server, not internet
    }

    @Test func modelOverrideReplacesTag() {
        let engine = VLMEngine(profile: .glmOCR, modelOverride: "glm-ocr-anova:q4_K_M")
        #expect(engine.resolvedModelTag == "glm-ocr-anova:q4_K_M")
        let defaulted = VLMEngine(profile: .glmOCR)
        #expect(defaulted.resolvedModelTag == "glm-ocr")
    }

    @Test func probeAgainstDeadPortReportsServerDown() async {
        let engine = VLMEngine(profile: .glmOCR, host: "localhost:59999")
        let availability = await engine.probe()
        guard case .unavailable(let reason, let hint) = availability else {
            Issue.record("expected unavailable, got \(availability)")
            return
        }
        #expect(reason.contains("Ollama"))
        #expect(hint == "ollama serve")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VLMEngineTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ModelProfile' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/Engines/ModelProfile.swift`:

```swift
/// Per-model quirks live here, not at call sites (spec §8): prompt contract,
/// default Ollama tag, output level. Roster mirrors evidence/candidates.json
/// admitted models (T2, 2026-07-20).
public struct ModelProfile: Sendable {
    public let id: String           // stable profile id → engine id "vlm.<id>"
    public let ollamaModel: String  // default Ollama tag; CLI --model overrides
    public let prompt: String
    public let outputLevel: OutputLevel

    /// The instrument's shared instruction prompt (measureOCR Prompt.ocr),
    /// duplicated verbatim so the product never imports the frozen instrument.
    public static let sharedInstructionPrompt =
        "Convert this document page to Markdown. Render all mathematical formulas as LaTeX (inline $...$, display $$...$$). Reproduce headings, lists and tables. Output only the transcription, no commentary."

    public static let glmOCR = ModelProfile(
        id: "glm-ocr", ollamaModel: "glm-ocr",
        prompt: sharedInstructionPrompt, outputLevel: .mathMarkdown)

    public static let ovisOCR2 = ModelProfile(
        id: "ovisocr2", ollamaModel: "ovisocr2",
        prompt: sharedInstructionPrompt, outputLevel: .mathMarkdown)

    /// candidates.json caveat (2026-07-20): REQUIRES the native task prompt —
    /// generic instruction prompts yield degenerate loops. Math arrives as
    /// \( \) not $ (delimiter normalization is deferred to M2 output work).
    public static let paddleOCRVL = ModelProfile(
        id: "paddleocr-vl", ollamaModel: "paddleocr-vl",
        prompt: "OCR:", outputLevel: .mathMarkdown)

    public static let all: [ModelProfile] = [glmOCR, ovisOCR2, paddleOCRVL]
}
```

`Sources/BestOCRKit/Engines/VLMEngine.swift`:

```swift
import Foundation
import OCRCore

/// Local VLM engine over the Ollama HTTP API, wrapping ocr-swift's
/// OllamaBackend (spec §5.4). One VLMEngine instance per model profile.
public struct VLMEngine: OCREngine {
    public let profile: ModelProfile
    public let host: String
    public let modelOverride: String?
    let fuse = RepetitionGuard()

    public var id: String { "vlm.\(profile.id)" }
    public let family = EngineFamily.localVLM

    public var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: profile.outputLevel,
                           languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                           needsNetwork: false,   // localhost server, not internet
                           memoryClass: .medium)
    }

    public var resolvedModelTag: String { modelOverride ?? profile.ollamaModel }

    public init(profile: ModelProfile, host: String = "localhost:11434",
                modelOverride: String? = nil) {
        self.profile = profile
        self.host = host
        self.modelOverride = modelOverride
    }

    /// GET /api/tags: distinguishes server-down from model-missing so the
    /// install hint is actionable (spec §8).
    public func probe() async -> EngineAvailability {
        guard let url = URL(string: "http://\(host)/api/tags") else {
            return .unavailable(reason: "invalid Ollama host \(host)", installHint: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            return .unavailable(reason: "Ollama server unreachable at \(host)",
                                installHint: "ollama serve")
        }
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            return .unavailable(reason: "Ollama at \(host) returned an unexpected /api/tags payload",
                                installHint: nil)
        }
        let wanted = resolvedModelTag
        let present = tags.models.contains {
            $0.name == wanted || $0.name.hasPrefix("\(wanted):")
        }
        guard present else {
            return .unavailable(reason: "model '\(wanted)' not present in Ollama",
                                installHint: "ollama pull \(wanted)  (or ollama create — see evidence/candidates.json)")
        }
        return .available
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        let backend = OllamaBackend(host: host, model: resolvedModelTag, prompt: profile.prompt)
        var pageResults: [PageResult] = []
        for page in request.pages {
            let data: Data
            do {
                data = try Data(contentsOf: page.url)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): cannot read \(page.url.path)")
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            let raw: String
            do {
                raw = try await backend.processImage(data)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            let flagged = fuse.flags(raw)
            var text = raw
            if flagged {
                text += "\n<!-- WARN: repetition-guard tripped — output may be degenerate -->"
                FileHandle.standardError.write(Data("[\(id)] page \(page.pageNumber): repetition guard tripped\n".utf8))
            }
            pageResults.append(PageResult(page: page.pageNumber, text: text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: flagged))
        }
        let condition = ConditionTuple(model: resolvedModelTag, quant: quantLabel(),
                                       dpi: request.dpi, docType: request.docType,
                                       platform: "ollama",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }

    /// Quant from the Ollama tag suffix ("glm-ocr-anova:q4_K_M" → "q4_K_M");
    /// untagged models report "default" (the tag's build decides).
    func quantLabel() -> String {
        let tag = resolvedModelTag
        guard let colon = tag.firstIndex(of: ":") else { return "default" }
        return String(tag[tag.index(after: colon)...])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VLMEngineTests 2>&1 | tail -5`
Expected: PASS — 6 tests (no live Ollama needed; the probe test uses a dead port).

- [ ] **Step 5: Live smoke against local Ollama (adjust default tags if needed)**

```bash
(ollama serve >/dev/null 2>&1 &) ; sleep 2
curl -s http://localhost:11434/api/tags | python3 -c "import json,sys; [print(m['name']) for m in json.load(sys.stdin)['models']]"
```

Expected: a list of local tags. If the GLM/Ovis/Paddle tags differ from the profile defaults (`glm-ocr` / `ovisocr2` / `paddleocr-vl`) — e.g. the machine has `glm-ocr-anova:q4_K_M` — update the `ollamaModel` values in `ModelProfile.swift` to the actual base tags and update the two affected `#expect` lines in `modelOverrideReplacesTag`. Re-run `swift test --filter VLMEngineTests` → PASS. (Model tags are data, not architecture; correcting them here is in-scope.)

- [ ] **Step 6: Commit**

```bash
git add Sources/BestOCRKit/Engines/ModelProfile.swift Sources/BestOCRKit/Engines/VLMEngine.swift Tests/BestOCRKitTests/VLMEngineTests.swift
git commit -m "feat: VLMEngine over Ollama + ModelProfile roster (glm-ocr, ovisocr2, paddleocr-vl)"
```

---

### Task 7: EngineRegistry

**Files:**
- Create: `Sources/BestOCRKit/EngineRegistry.swift`
- Test: `Tests/BestOCRKitTests/EngineRegistryTests.swift`

**Interfaces:**
- Consumes: `OCREngine`, engines from Tasks 4–6.
- Produces: `EngineRegistry(engines:[any OCREngine])`, `EngineRegistry.standard(ollamaHost:String) -> EngineRegistry`, `func engine(id:String) -> (any OCREngine)?`, `func probeAll() async -> [(engine: any OCREngine, availability: EngineAvailability)]`.

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/EngineRegistryTests.swift`:

```swift
import Testing
@testable import BestOCRKit

/// Minimal stub for registry-behaviour tests (also reused in Task 9).
struct StubEngine: OCREngine {
    let id: String
    let family = EngineFamily.classical
    let availability: EngineAvailability
    let text: String

    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText, languages: ["en"],
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

struct EngineRegistryTests {
    @Test func standardRosterHasFiveEngines() {
        let registry = EngineRegistry.standard()
        #expect(registry.engines.map(\.id) ==
                ["vision", "tesseract", "vlm.glm-ocr", "vlm.ovisocr2", "vlm.paddleocr-vl"])
    }

    @Test func lookupByIDAndUnknownReturnsNil() {
        let registry = EngineRegistry.standard()
        #expect(registry.engine(id: "vision") != nil)
        #expect(registry.engine(id: "nope") == nil)
    }

    @Test func probeAllPreservesOrderAndAvailability() async {
        let registry = EngineRegistry(engines: [
            StubEngine(id: "a", availability: .available, text: "x"),
            StubEngine(id: "b", availability: .unavailable(reason: "off", installHint: nil), text: "y"),
        ])
        let probed = await registry.probeAll()
        #expect(probed.map(\.engine.id) == ["a", "b"])
        #expect(probed[0].availability == .available)
        #expect(probed[1].availability == .unavailable(reason: "off", installHint: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EngineRegistryTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'EngineRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/EngineRegistry.swift`:

```swift
/// The engine roster (spec §4): construction is explicit so tests can inject
/// stubs; `standard()` is the production wiring used by the CLI.
public struct EngineRegistry: Sendable {
    public let engines: [any OCREngine]

    public init(engines: [any OCREngine]) {
        self.engines = engines
    }

    /// M1 roster: Vision + tesseract + one VLM engine per admitted profile.
    public static func standard(ollamaHost: String = "localhost:11434") -> EngineRegistry {
        var engines: [any OCREngine] = [VisionEngine(), TesseractEngine()]
        engines.append(contentsOf: ModelProfile.all.map {
            VLMEngine(profile: $0, host: ollamaHost)
        })
        return EngineRegistry(engines: engines)
    }

    public func engine(id: String) -> (any OCREngine)? {
        engines.first { $0.id == id }
    }

    public func probeAll() async -> [(engine: any OCREngine, availability: EngineAvailability)] {
        var out: [(engine: any OCREngine, availability: EngineAvailability)] = []
        for engine in engines {
            out.append((engine, await engine.probe()))
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EngineRegistryTests 2>&1 | tail -5`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/EngineRegistry.swift Tests/BestOCRKitTests/EngineRegistryTests.swift
git commit -m "feat: EngineRegistry — explicit roster with probe-all"
```

---

### Task 8: RunLog (JSONL run records)

**Files:**
- Create: `Sources/BestOCRKit/RunLog.swift`
- Test: `Tests/BestOCRKitTests/RunLogTests.swift`

**Interfaces:**
- Consumes: `OCRResult`, `ConditionTuple`, `PageResult` (Task 1).
- Produces: `RunLogEntry(from result:OCRResult, input:String, output:String)` (fields `id:String`, `timestamp:String`, `input`, `output`, `engineID`, `condition:ConditionTuple`, `pages:[PageStat]` where `PageStat(page:seconds:thermalState:degenerateFlagged:)`); `RunLog(fileURL:URL)`, `RunLog.default()` (honours `BESTOCR_RUNLOG` env, else `~/.bestocr/runlog.jsonl`), `func append(_ entry:RunLogEntry) throws`.

- [ ] **Step 1: Write the failing test**

`Tests/BestOCRKitTests/RunLogTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct RunLogTests {
    func sampleResult() -> OCRResult {
        let condition = ConditionTuple(model: "vision", quant: "n/a", dpi: 150,
                                       docType: "math_pdf", platform: "vision",
                                       hardware: "test", instrument: BestOCRVersion.string)
        return OCRResult(engineID: "vision", pages: [
            PageResult(page: 1, text: "hello", seconds: 0.5,
                       thermalState: "nominal", degenerateFlagged: false),
        ], condition: condition)
    }

    @Test func appendWritesOneJSONLinePerEntry() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlog-\(UUID().uuidString).jsonl")
        let log = RunLog(fileURL: file)
        let entry1 = RunLogEntry(from: sampleResult(), input: "/a.pdf", output: "/out/a.md")
        let entry2 = RunLogEntry(from: sampleResult(), input: "/b.png", output: "/out/b.md")
        try log.append(entry1)
        try log.append(entry2)
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        // Each line is standalone JSON with the evidence-aligned condition.
        let decoded = try JSONDecoder().decode(RunLogEntry.self, from: Data(lines[0].utf8))
        #expect(decoded.engineID == "vision")
        #expect(decoded.condition.docType == "math_pdf")
        #expect(decoded.pages.count == 1)
        #expect(decoded.id == entry1.id)
    }

    @Test func entriesCarryDistinctIDsAndISO8601Timestamps() {
        let e1 = RunLogEntry(from: sampleResult(), input: "/a.pdf", output: "/o.md")
        let e2 = RunLogEntry(from: sampleResult(), input: "/a.pdf", output: "/o.md")
        #expect(e1.id != e2.id)
        #expect(e1.timestamp.contains("T"))   // ISO8601 marker
    }

    @Test func defaultHonoursEnvOverride() {
        setenv("BESTOCR_RUNLOG", "/tmp/custom-runlog.jsonl", 1)
        defer { unsetenv("BESTOCR_RUNLOG") }
        #expect(RunLog.default().fileURL.path == "/tmp/custom-runlog.jsonl")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RunLogTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'RunLog' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/BestOCRKit/RunLog.swift`:

```swift
import Foundation

/// One run's provenance record (spec §6.2): metadata only — page text lives
/// in the output files. Nothing here auto-promotes to evidence/; the explicit
/// `evidence ingest` gate arrives in M4.
public struct RunLogEntry: Codable, Sendable {
    public struct PageStat: Codable, Sendable {
        public let page: Int
        public let seconds: Double
        public let thermalState: String
        public let degenerateFlagged: Bool
    }

    public let id: String
    public let timestamp: String     // ISO8601
    public let input: String
    public let output: String
    public let engineID: String
    public let condition: ConditionTuple
    public let pages: [PageStat]

    public init(from result: OCRResult, input: String, output: String) {
        self.id = UUID().uuidString
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.input = input
        self.output = output
        self.engineID = result.engineID
        self.condition = result.condition
        self.pages = result.pages.map {
            PageStat(page: $0.page, seconds: $0.seconds,
                     thermalState: $0.thermalState,
                     degenerateFlagged: $0.degenerateFlagged)
        }
    }
}

/// Append-only JSONL log at a fixed path (spec §6 data flow).
public struct RunLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `BESTOCR_RUNLOG` env override (tests, alternate stores), else
    /// `~/.bestocr/runlog.jsonl`.
    public static func `default`() -> RunLog {
        if let override = ProcessInfo.processInfo.environment["BESTOCR_RUNLOG"] {
            return RunLog(fileURL: URL(fileURLWithPath: override))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return RunLog(fileURL: home.appendingPathComponent(".bestocr/runlog.jsonl"))
    }

    public func append(_ entry: RunLogEntry) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry)
        line.append(Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RunLogTests 2>&1 | tail -5`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/BestOCRKit/RunLog.swift Tests/BestOCRKitTests/RunLogTests.swift
git commit -m "feat: RunLog JSONL provenance records (explicit-ingest groundwork)"
```

---

### Task 9: RunPipeline + CLI (`run`, `list-engines`)

**Files:**
- Create: `Sources/BestOCRKit/RunPipeline.swift`
- Modify: `Sources/bestocr/BestOCRMain.swift` (replace the Task-1 placeholder entirely)
- Create: `Sources/bestocr/RunCommand.swift`
- Create: `Sources/bestocr/ListEnginesCommand.swift`
- Test: `Tests/BestOCRKitTests/RunPipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–8; `StubEngine` (defined in Task 7's test file, same test target).
- Produces: `RunSummary(runID:String, outputMarkdown:URL, outputMeta:URL, result:OCRResult)`; `RunPipeline.execute(inputPath:engineID:dpi:pageSpec:languages:docType:outDir:registry:runLog:) async throws -> RunSummary`. CLI: `bestocr run <input> --engine <id> [--out DIR] [--dpi N] [--pages SPEC] [--lang CSV] [--doc-type LABEL] [--model TAG]`, `bestocr list-engines`.

- [ ] **Step 1: Write the failing pipeline test**

`Tests/BestOCRKitTests/RunPipelineTests.swift`:

```swift
import Foundation
import Testing
@testable import BestOCRKit

struct RunPipelineTests {
    func makeEnv() throws -> (outDir: URL, runLog: RunLog) {
        let base = try Fixtures.tempDir()
        return (base.appendingPathComponent("out", isDirectory: true),
                RunLog(fileURL: base.appendingPathComponent("runlog.jsonl")))
    }

    @Test func executeWritesMarkdownMetaAndRunlog() async throws {
        let (outDir, runLog) = try makeEnv()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "stub", availability: .available, text: "STUB TEXT"),
        ])
        let img = try Fixtures.textImage("HELLO")
        let summary = try await RunPipeline.execute(
            inputPath: img.path, engineID: "stub", dpi: 150, pageSpec: "",
            languages: [], docType: "screenshot", outDir: outDir,
            registry: registry, runLog: runLog)

        let md = try String(contentsOf: summary.outputMarkdown, encoding: .utf8)
        #expect(md.contains("STUB TEXT"))
        #expect(summary.outputMarkdown.lastPathComponent == "fixture.md")
        #expect(summary.outputMeta.lastPathComponent == "fixture.meta.json")

        let meta = try JSONDecoder().decode(OCRResult.self,
                                            from: Data(contentsOf: summary.outputMeta))
        #expect(meta.condition.docType == "screenshot")

        let lines = try String(contentsOf: runLog.fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)
    }

    @Test func unknownEngineListsValidIDs() async throws {
        let (outDir, runLog) = try makeEnv()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "stub", availability: .available, text: "x"),
        ])
        let img = try Fixtures.textImage("X")
        await #expect(throws: OCREngineError.self) {
            _ = try await RunPipeline.execute(
                inputPath: img.path, engineID: "ghost", dpi: 150, pageSpec: "",
                languages: [], docType: "unspecified", outDir: outDir,
                registry: registry, runLog: runLog)
        }
    }

    @Test func unavailableEngineFailsWithReasonAndHint() async throws {
        let (outDir, runLog) = try makeEnv()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "off",
                       availability: .unavailable(reason: "not installed", installHint: "brew install off"),
                       text: "x"),
        ])
        let img = try Fixtures.textImage("X")
        do {
            _ = try await RunPipeline.execute(
                inputPath: img.path, engineID: "off", dpi: 150, pageSpec: "",
                languages: [], docType: "unspecified", outDir: outDir,
                registry: registry, runLog: runLog)
            Issue.record("expected throw")
        } catch let error as OCREngineError {
            #expect(error.message.contains("not installed"))
            #expect(error.message.contains("brew install off"))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RunPipelineTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'RunPipeline' in scope`.

- [ ] **Step 3: Write the pipeline implementation**

`Sources/BestOCRKit/RunPipeline.swift`:

```swift
import Foundation

/// Result of one CLI/MCP run: where the outputs landed + the full OCRResult.
public struct RunSummary: Sendable {
    public let runID: String
    public let outputMarkdown: URL
    public let outputMeta: URL
    public let result: OCRResult
}

/// The shared run flow (spec §6, §7): probe → normalize → recognize → write
/// outputs → append run log. CLI and (M3) MCP are thin shells over this.
public enum RunPipeline {
    public static func execute(inputPath: String, engineID: String, dpi: Double,
                               pageSpec: String, languages: [String], docType: String,
                               outDir: URL, registry: EngineRegistry,
                               runLog: RunLog) async throws -> RunSummary {
        guard let engine = registry.engine(id: engineID) else {
            let valid = registry.engines.map(\.id).joined(separator: ", ")
            throw OCREngineError(engine: engineID,
                                 message: "unknown engine — valid ids: \(valid)")
        }
        if case .unavailable(let reason, let hint) = await engine.probe() {
            var message = "unavailable: \(reason)"
            if let hint { message += " — install: \(hint)" }
            throw OCREngineError(engine: engineID, message: message)
        }

        let normalized = try InputNormalizer.normalize(
            inputPath: inputPath, dpi: dpi, pageSpec: pageSpec, workDir: nil)
        defer { normalized.cleanup() }

        let request = OCRRequest(pages: normalized.pages, languages: languages,
                                 dpi: normalized.dpi, docType: docType)
        let result = try await engine.recognize(request)

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let mdURL = outDir.appendingPathComponent("\(stem).md")
        let combined = result.pages.map(\.text).joined(separator: "\n\n---\n\n")
        try combined.write(to: mdURL, atomically: true, encoding: .utf8)

        let metaURL = outDir.appendingPathComponent("\(stem).meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: metaURL)

        let entry = RunLogEntry(from: result, input: inputPath, output: mdURL.path)
        try runLog.append(entry)
        return RunSummary(runID: entry.id, outputMarkdown: mdURL,
                          outputMeta: metaURL, result: result)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RunPipelineTests 2>&1 | tail -5`
Expected: PASS — 3 tests.

- [ ] **Step 5: Write the CLI**

Replace `Sources/bestocr/BestOCRMain.swift` entirely:

```swift
import ArgumentParser

@main
struct BestOCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bestocr",
        abstract: "Evidence-based multi-engine OCR (M1: explicit engine selection; auto-routing arrives with recommend in M2).",
        subcommands: [Run.self, ListEngines.self]
    )
}
```

`Sources/bestocr/RunCommand.swift`:

```swift
import ArgumentParser
import BestOCRKit
import Foundation

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "OCR a PDF or image with an explicitly chosen engine.")

    @Argument(help: "Input file (pdf, png, jpg, jpeg, tiff, heic, bmp).")
    var input: String

    @Option(help: "Engine id — see `bestocr list-engines`.")
    var engine: String

    @Option(help: "Output directory for <stem>.md and <stem>.meta.json.")
    var out: String = "."

    @Option(help: "Render DPI for PDF inputs (evidence factor).")
    var dpi: Double = 150

    @Option(help: "Page spec for PDFs, e.g. \"1-3,7\" (default: all pages).")
    var pages: String = ""

    @Option(help: "Comma-separated language preference, e.g. \"zh-Hant,en\".")
    var lang: String = ""

    @Option(name: .customLong("doc-type"),
            help: "Workload label recorded in the condition tuple (e.g. math_pdf, scanned_book, screenshot).")
    var docType: String = "unspecified"

    @Option(help: "Override the VLM model tag (vlm.* engines only), e.g. glm-ocr-anova:q4_K_M.")
    var model: String?

    mutating func run() async throws {
        var registry = EngineRegistry.standard()
        if let model {
            guard engine.hasPrefix("vlm.") else {
                throw ValidationError("--model only applies to vlm.* engines (got \(engine))")
            }
            // Rebuild the chosen VLM engine with the override tag.
            let engines: [any OCREngine] = registry.engines.map { existing in
                guard existing.id == engine, let vlm = existing as? VLMEngine else { return existing }
                return VLMEngine(profile: vlm.profile, host: vlm.host, modelOverride: model)
            }
            registry = EngineRegistry(engines: engines)
        }
        let languages = lang.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        do {
            let summary = try await RunPipeline.execute(
                inputPath: input, engineID: engine, dpi: dpi, pageSpec: pages,
                languages: languages, docType: docType,
                outDir: URL(fileURLWithPath: out),
                registry: registry, runLog: RunLog.default())
            let pageCount = summary.result.pages.count
            let total = summary.result.pages.map(\.seconds).reduce(0, +)
            print("✓ \(engine): \(pageCount) page(s) in \(String(format: "%.1f", total))s")
            print("  markdown: \(summary.outputMarkdown.path)")
            print("  meta:     \(summary.outputMeta.path)")
            if summary.result.pages.contains(where: \.degenerateFlagged) {
                print("  ⚠ repetition guard tripped on at least one page — inspect the output")
            }
        } catch let error as OCREngineError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        }
    }
}
```

`Sources/bestocr/ListEnginesCommand.swift`:

```swift
import ArgumentParser
import BestOCRKit

struct ListEngines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-engines",
        abstract: "Probe every registered engine and show availability + install hints.")

    mutating func run() async throws {
        let registry = EngineRegistry.standard()
        let probed = await registry.probeAll()
        let idWidth = max(probed.map { $0.engine.id.count }.max() ?? 0, 6)
        print("\("ENGINE".padding(toLength: idWidth, withPad: " ", startingAt: 0))  FAMILY           OUTPUT         STATUS")
        for (engine, availability) in probed {
            let status: String
            switch availability {
            case .available:
                status = "✓ available"
            case .unavailable(let reason, let hint):
                status = "✗ \(reason)" + (hint.map { " — install: \($0)" } ?? "")
            }
            let id = engine.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let family = engine.family.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
            let output = engine.capabilities.outputLevel.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            print("\(id)  \(family)  \(output)  \(status)")
        }
    }
}
```

- [ ] **Step 6: Build and smoke the CLI end-to-end**

```bash
swift build 2>&1 | tail -3
.build/debug/bestocr list-engines
```

Expected: table with 5 rows — `vision` and `tesseract` show `✓ available`; `vlm.*` rows show `✓` if Ollama is up with the models, otherwise `✗` with the `ollama serve` / `ollama pull` hint.

```bash
/usr/bin/python3 -c "
from AppKit import NSImage  # noqa — placeholder guard
" 2>/dev/null; screencapture -x /tmp/bestocr-smoke.png 2>/dev/null || true
.build/debug/bestocr run /tmp/bestocr-smoke.png --engine vision --out /tmp/bestocr-out --doc-type screenshot
cat /tmp/bestocr-out/bestocr-smoke.md | head -5
```

Expected: `✓ vision: 1 page(s) in …s`, markdown file contains recognizable screen text. (If `screencapture` yields an empty screen, any PNG with text works.)

- [ ] **Step 7: Run the full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: ALL PASS (≈27 tests; tesseract integration included since the binary is installed).

- [ ] **Step 8: Commit**

```bash
git add Sources/BestOCRKit/RunPipeline.swift Sources/bestocr Tests/BestOCRKitTests/RunPipelineTests.swift
git commit -m "feat: RunPipeline + bestocr CLI (run, list-engines)"
```

---

### Task 10: README + final verification

**Files:**
- Modify: `README.md` (root) — replace the "Status: scaffold" paragraph and add a Usage section
- Test: full suite + manual smoke (no new test files)

**Interfaces:**
- Consumes: the finished M1 CLI.

- [ ] **Step 1: Update README**

In `README.md`, replace the paragraph starting `**Status: scaffold.**` with:

```markdown
**Status: M1 — engine layer + CLI.** `bestocr run` executes any locally
available engine (Apple Vision, tesseract, Ollama VLMs) with explicit
selection; every run records the full evidence condition tuple to
`~/.bestocr/runlog.jsonl`. `recommend`, auto-routing, MCP, and external
Python adapters land in M2–M4 (see
`docs/superpowers/specs/2026-07-21-multi-platform-ocr-design.md`). The
recommendation layer still ships only after the pre-registered sweep produces
real evidence — `recommend` before that returns an honest *evidence-pending*
answer, not a guess.
```

And append after the "Layout" section:

```markdown
## Usage (M1)

```bash
swift build -c release
.build/release/bestocr list-engines             # probe table + install hints
.build/release/bestocr run page.png --engine vision --doc-type screenshot
.build/release/bestocr run paper.pdf --engine vlm.glm-ocr --dpi 150 --pages 1-3 \
    --doc-type math_pdf --out out/
```

Engine ids: `vision`, `tesseract`, `vlm.glm-ocr`, `vlm.ovisocr2`,
`vlm.paddleocr-vl` (VLM engines need a running `ollama serve` with the model
present; `--model` overrides the tag, e.g. `--model glm-ocr-anova:q4_K_M`).
```

Also update the "Layout" block to add the new directories:

```markdown
Sources/BestOCRKit    engine layer: OCREngine protocol, engines, router pipeline
Sources/bestocr       CLI (thin shell over BestOCRKit)
Tests/BestOCRKitTests Swift Testing suite (programmatic fixtures, no binaries)
```

- [ ] **Step 2: Full verification**

```bash
swift test 2>&1 | tail -3          # ALL PASS
swift build -c release 2>&1 | tail -2   # builds clean (Vision deprecation warnings OK)
.build/release/bestocr list-engines
```

Expected: tests pass, release builds, probe table renders.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README M1 status + usage (engine layer + CLI shipped)"
```

---

## Plan Self-Review (done at authoring time)

- **Spec coverage (M1 slice)**: §5.1 protocol → T1; §5.2 normalization → T3; §5.3 condition tuple → T1/T4–T6; §5.4 roster (M1 rows) → T4–T6; §6.2 run log → T8; §7 Flow B (`run`, `list-engines`) → T9; §8 probe/containment/fuse/quirk-profiles → T2, T5, T6; §9 test rules → every task + availability-guarded T5/T6. Deliberately out of M1: recommend/auto-route (M2), adapters (M2), MCP (M3), cloud + ingest (M4), fallback chain (spec §8 — arrives with auto-routing in M2, since M1 runs are explicit-engine).
- **Placeholder scan**: none — every step carries complete code/commands.
- **Type consistency**: `ConditionTuple(model:quant:dpi:docType:platform:hardware:instrument:)`, `PageResult(page:text:seconds:thermalState:degenerateFlagged:)`, `OCRRequest(pages:languages:dpi:docType:)`, `EngineAvailability.unavailable(reason:installHint:)` used with identical signatures across Tasks 1–9; `StubEngine` defined once (T7) and reused (T9, same test target).
