import Foundation
import Testing
@testable import BestOCRKit
@testable import BestOCRMCPCore
import MCP

/// Stub engine local to this target (BestOCRKitTests' StubEngine is invisible here).
struct MCPStubEngine: OCREngine {
    let id: String
    let family = EngineFamily.classical
    var text = "STUB TEXT"

    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                           needsNetwork: false, memoryClass: .light)
    }

    func probe() async -> EngineAvailability { .available }

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

struct ServerTests {
    func makeServer() throws -> (server: BestOCRMCPServer, tmpDir: URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bestocr-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let server = BestOCRMCPServer(
            registry: EngineRegistry(engines: [MCPStubEngine(id: "stub")]),
            runLog: RunLog(fileURL: tmpDir.appendingPathComponent("runlog.jsonl")),
            evidenceURL: tmpDir.appendingPathComponent("rows.jsonl"))
        return (server, tmpDir)
    }

    /// Draws a tiny PNG fixture (no cross-target Fixtures access).
    func fixtureImage(in dir: URL) throws -> URL {
        // A 1×1 white PNG is enough for the stub engine (it never reads pixels).
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")!
        let url = dir.appendingPathComponent("fixture.png")
        try png.write(to: url)
        return url
    }

    func firstText(_ result: CallTool.Result) -> String {
        if case .text(let t, _, _)? = result.content.first { return t }
        return ""
    }

    @Test func toolListAndDispatchAgree() async throws {
        let names = Set(BestOCRMCPServer.defineTools().map(\.name))
        #expect(names == ["ocr", "consensus", "recommend", "list_engines", "list_models",
                          "ocr_status", "ocr_result"])
        let (server, _) = try makeServer()
        for name in names {
            let result = await server.execute(name: name, arguments: [:])
            #expect(!firstText(result).contains("unknown tool"), "\(name) fell through dispatch")
        }
    }

    @Test func unknownToolIsLoudError() async throws {
        let (server, _) = try makeServer()
        let result = await server.execute(name: "nope", arguments: [:])
        #expect(result.isError == true)
        #expect(firstText(result).contains("unknown tool"))
    }

    @Test func ocrHappyPathWritesOutputs() async throws {
        let (server, tmpDir) = try makeServer()
        let img = try fixtureImage(in: tmpDir)
        let outDir = tmpDir.appendingPathComponent("out").path
        let result = await server.execute(name: "ocr", arguments: [
            "input_path": .string(img.path),
            "engine": .string("stub"),
            "out_dir": .string(outDir),
            "doc_type": .string("screenshot"),
        ])
        let text = firstText(result)
        #expect(result.isError != true)
        #expect(text.contains("✓ stub"))
        #expect(FileManager.default.fileExists(atPath: "\(outDir)/fixture.md"))
        let log = try String(contentsOf: tmpDir.appendingPathComponent("runlog.jsonl"),
                             encoding: .utf8)
        #expect(log.split(separator: "\n").count == 1)
    }

    @Test func ocrMissingArgIsError() async throws {
        let (server, _) = try makeServer()
        let result = await server.execute(name: "ocr", arguments: ["engine": .string("stub")])
        #expect(result.isError == true)
        #expect(firstText(result).contains("input_path"))
    }

    @Test func asyncOCRRoundTrip() async throws {
        let (server, tmpDir) = try makeServer()
        let img = try fixtureImage(in: tmpDir)
        let started = await server.execute(name: "ocr", arguments: [
            "input_path": .string(img.path),
            "engine": .string("stub"),
            "out_dir": .string(tmpDir.appendingPathComponent("out2").path),
            "async": .bool(true),
        ])
        let startText = firstText(started)
        #expect(startText.contains("job_id:"))
        let jobID = startText.split(separator: "\n")
            .first { $0.hasPrefix("job_id:") }!
            .dropFirst("job_id:".count).trimmingCharacters(in: .whitespaces)
        let result = await server.execute(name: "ocr_result",
                                          arguments: ["job_id": .string(jobID)])
        #expect(firstText(result).contains("✓ stub"))
        let status = await server.execute(name: "ocr_status",
                                          arguments: ["job_id": .string(jobID)])
        #expect(firstText(status).contains("done"))
    }

    @Test func ocrWithoutEngineRoutesAutomatically() async throws {
        let (server, tmpDir) = try makeServer()
        let img = try fixtureImage(in: tmpDir)
        let result = await server.execute(name: "ocr", arguments: [
            "input_path": .string(img.path),
            "out_dir": .string(tmpDir.appendingPathComponent("auto-out").path),
            "doc_type": .string("screenshot"),
        ])
        #expect(result.isError != true)
        #expect(firstText(result).contains("✓ stub"))   // auto picked the only stub
    }

    @Test func recommendEvidencePendingRendered() async throws {
        let (server, _) = try makeServer()
        let result = await server.execute(name: "recommend", arguments: [
            "doc_type": .string("math_pdf"),
        ])
        #expect(firstText(result).contains("EVIDENCE-PENDING"))
    }
}
