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

    @Test func adapterScriptMaterializesAndRefreshes() throws {
        let dir = try Fixtures.tempDir()
        setenv("BESTOCR_ADAPTER_DIR", dir.path, 1)
        defer { unsetenv("BESTOCR_ADAPTER_DIR") }
        let engine = ExternalToolEngine.rapidocr()
        let url = try #require(engine.scriptURL())
        #expect(FileManager.default.fileExists(atPath: url.path))
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("rapidocr"))
        // Corrupt the materialized copy → next resolve rewrites it.
        try "corrupted".write(to: url, atomically: true, encoding: .utf8)
        let again = try #require(engine.scriptURL())
        #expect(try String(contentsOf: again, encoding: .utf8).contains("rapidocr"))
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
