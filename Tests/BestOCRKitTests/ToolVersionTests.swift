import Foundation
import Testing
@testable import BestOCRKit

/// #28 — the measuring tool's version enters the condition tuple, so rows
/// measured across a tool upgrade stop being silently indistinguishable.
///
/// The version travels in the protocol-v1 `ocr` / `assemble` REPLY — measured by
/// the process that produced the output — not in the probe, whose interpreter is
/// re-resolved by the time recognize runs (TOCTOU).
struct ToolVersionTests {
    // MARK: - ConditionTuple shape (the decode-compat half of the contract)

    /// Every row committed before this change lacks the key and must keep
    /// decoding — same additive-optional precedent as `OCRResult.document` (#16).
    @Test func legacyTupleWithoutToolVersionStillDecodes() throws {
        let legacy = """
        {"doc_type":"scanned_doc","dpi":150,"hardware":"test",
        "instrument":"bestocr 0.6.2","model":"surya","platform":"python",
        "quant":"n/a"}
        """
        let tuple = try JSONDecoder().decode(ConditionTuple.self, from: Data(legacy.utf8))
        #expect(tuple.toolVersion == nil)
    }

    @Test func tupleWithToolVersionDecodesAndMatchesSchemaKey() throws {
        let json = """
        {"doc_type":"scanned_doc","dpi":150,"hardware":"test",
        "instrument":"bestocr 0.8.0","model":"surya","platform":"python",
        "quant":"n/a","tool_version":"0.17.1"}
        """
        let tuple = try JSONDecoder().decode(ConditionTuple.self, from: Data(json.utf8))
        #expect(tuple.toolVersion == "0.17.1")
    }

    /// Presence is meaning: nil must OMIT the key (a legacy-shaped row), a value
    /// must emit `tool_version` verbatim (schema.md §3 vocabulary).
    @Test func encodingOmitsNilAndEmitsSnakeCaseKey() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func tuple(_ version: String?) -> ConditionTuple {
            ConditionTuple(model: "surya", quant: "n/a", dpi: nil, docType: "scanned_doc",
                           platform: "python", hardware: "test", instrument: "test",
                           toolVersion: version)
        }
        let without = String(decoding: try encoder.encode(tuple(nil)), as: UTF8.self)
        #expect(!without.contains("tool_version"))
        let with = String(decoding: try encoder.encode(tuple("0.22.1")), as: UTF8.self)
        #expect(with.contains("\"tool_version\":\"0.22.1\""))
    }

    // MARK: - ExternalToolEngine threads the reply's version into the tuple

    static let caps = EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                                         needsNetwork: false, memoryClass: .light)

    func engine(script: String) throws -> ExternalToolEngine {
        let url = try Fixtures.tempDir().appendingPathComponent("adapter.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return ExternalToolEngine(tool: "fake", capabilities: Self.caps,
                                  installHint: "pip install fake", script: url, timeout: 30)
    }

    @Test func replyVersionReachesTheConditionTuple() async throws {
        let engine = try engine(script: """
        import json
        print(json.dumps({"protocol": 1, "text": "T", "version": "9.9.9"}))
        """)
        let img = try Fixtures.textImage("X")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], docType: "screenshot"))
        #expect(result.condition.toolVersion == "9.9.9")
    }

    /// An old adapter (or an overridden script) that says nothing about its
    /// version stays valid — absence decodes as nil, never an error.
    @Test func versionlessReplyStaysValidWithNilVersion() async throws {
        let engine = try engine(script: """
        import json
        print(json.dumps({"protocol": 1, "text": "T"}))
        """)
        let img = try Fixtures.textImage("X")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], docType: "screenshot"))
        #expect(result.condition.toolVersion == nil)
    }

    // MARK: - DocumentPipelineEngine does the same for assemble replies

    @Test func assembleReplyVersionReachesTheTuple() throws {
        let engine = DocumentPipelineEngine.paddleOCRPipeline()
        let reply = try JSONDecoder().decode(
            DocumentPipelineEngine.AssembleReply.self, from: Data("""
            {"protocol":1,"load_seconds":1.0,"version":"3.7.0 (PaddleOCRVL)",
             "pages":[{"page":1,"text":"x","seconds":1.0}],
             "blocks":[{"page":1,"kind":"paragraph","text":"x"}]}
            """.utf8))
        let request = OCRRequest(pages: [PageImage(pageNumber: 1,
                                                   url: URL(fileURLWithPath: "/tmp/p1.png"))],
                                 dpi: 150, docType: "multicolumn_scan")
        let result = try engine.wholeDocumentResult(reply: reply, request: request)
        #expect(result.condition.toolVersion == "3.7.0 (PaddleOCRVL)")
    }

    @Test func assembleReplyWithoutVersionDecodesNil() throws {
        let reply = try JSONDecoder().decode(
            DocumentPipelineEngine.AssembleReply.self, from: Data("""
            {"protocol":1,"pages":[{"page":1,"text":"x","seconds":1.0}],"blocks":[]}
            """.utf8))
        #expect(reply.version == nil)
    }

    // MARK: - The embedded adapters actually emit a version

    /// The classic adapters never had a compile check (the doc adapters do).
    @Test(arguments: ["rapidocr", "cnocr", "surya"])
    func classicAdapterIsValidPython(tool: String) throws {
        guard let python = AdapterProtocolV1.locatePython() else {
            print("SKIP: no python3")
            return
        }
        let content = try #require(AdapterScripts.script(for: tool))
        let url = try Fixtures.tempDir().appendingPathComponent("bestocr-\(tool)-adapter.py")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let run = try Subprocess.run(python, arguments: ["-m", "py_compile", url.path],
                                    timeout: 60)
        #expect(run.exitCode == 0, "\(tool): \(run.stderr)")
    }

    /// #28's incidental bug, pinned live: surya 0.17.1 has no `__version__`, so
    /// the old probe answered "unknown" while looking like it checked. With the
    /// tool installed, the probe must now report the dist-info version. Skips
    /// honestly where the tool is absent.
    @Test(arguments: ["rapidocr", "cnocr", "surya"])
    func probeReportsARealVersionWhenTheToolIsInstalled(tool: String) throws {
        guard let python = AdapterProtocolV1.locatePython() else {
            print("SKIP: no python3")
            return
        }
        let content = try #require(AdapterScripts.script(for: tool))
        let url = try Fixtures.tempDir().appendingPathComponent("bestocr-\(tool)-adapter.py")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let run = try Subprocess.run(python, arguments: [url.path, "probe"], timeout: 120)
        #expect(run.exitCode == 0)
        let data = try #require(AdapterProtocolV1.lastJSONLine(run.stdout))
        let probe = try JSONDecoder().decode(AdapterProtocolV1.ProbeReply.self, from: data)
        guard probe.ok else {
            print("SKIP: \(tool) not importable on this machine (\(probe.reason ?? "?"))")
            return
        }
        let version = try #require(probe.version)
        #expect(version != "unknown", "\(tool) is installed but the probe cannot name its version")
        #expect(!version.isEmpty)
    }
}
