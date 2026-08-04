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

    func resolveVersion() async -> EngineVersion { .unavailable }

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
        #expect(names == ["ocr", "pipeline", "consensus", "triage", "recommend", "list_engines",
                          "list_models", "ocr_status", "ocr_result"])
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

    /// The delivery path has to be reachable through MCP, otherwise a skill that
    /// delegates to it breaks for every plugin user — the wrapper installs the
    /// MCP binary, not the CLI.
    @Test func pipelineRunsThroughMCPAndProducesADeliverable() async throws {
        guard FileConverter.locate(.pandoc) != nil || FileConverter.locate(.macdoc) != nil else {
            print("SKIP: no converter installed")
            return
        }
        let (server, tmpDir) = try makeServer()
        let img = try fixtureImage(in: tmpDir)
        let outDir = tmpDir.appendingPathComponent("delivery").path
        let result = await server.execute(name: "pipeline", arguments: [
            "input_path": .string(img.path),
            "engine": .string("stub"),
            "out_dir": .string(outDir),
            "doc_type": .string("screenshot"),
        ])
        let text = firstText(result)
        #expect(result.isError != true, "\(text)")
        #expect(text.contains("1 succeeded, 0 failed"))
        #expect(text.contains("converter:"))
        try DocxValidator.validate(URL(fileURLWithPath: "\(outDir)/fixture.docx"))
    }

    /// The refusal must survive the MCP boundary: an agent calling this tool
    /// gets the same protection a person at the CLI does.
    @Test func pipelineRefusesToOverwriteThroughMCPToo() async throws {
        let (server, tmpDir) = try makeServer()
        let img = try fixtureImage(in: tmpDir)
        let outDir = tmpDir.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = outDir.appendingPathComponent("fixture.docx")
        try "hand made".write(to: target, atomically: true, encoding: .utf8)

        let result = await server.execute(name: "pipeline", arguments: [
            "input_path": .string(img.path),
            "engine": .string("stub"),
            "out_dir": .string(outDir.path),
        ])
        #expect(result.isError == true)
        #expect(firstText(result).contains("--overwrite"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "hand made")
    }

    @Test func pipelineMissingInputIsError() async throws {
        let (server, _) = try makeServer()
        let result = await server.execute(name: "pipeline", arguments: [:])
        #expect(result.isError == true)
        #expect(firstText(result).contains("input_path"))
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

    /// Task 2.2 parity contract: the MCP tool's JSON decodes to the exact
    /// report runComplete produces for the same input (field-for-field, via
    /// Equatable — encoders differ in formatting, so compare decoded values).
    @Test func triageToolMatchesRunCompleteFieldForField() async throws {
        let (server, tmpDir) = try makeServer()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let img = try fixtureImage(in: tmpDir)
        let result = await server.execute(name: "triage", arguments: [
            "input_path": .string(img.path),
        ])
        let payload = firstText(result)
        let viaMCP = try JSONDecoder().decode(TriageReport.self, from: Data(payload.utf8))
        let direct = try await TriageProbe.runComplete(inputPath: img.path)
        #expect(viaMCP == direct)
        #expect(viaMCP.route == .ocrFull)   // image input: single no-text-layer page
    }

    // MARK: - #39: single-consensus check rendering

    private func summaryFixture(check: SingleConsensusCheck?) -> ConsensusRunSummary {
        ConsensusRunSummary(
            outputMarkdown: URL(fileURLWithPath: "/tmp/x.consensus.md"),
            outputReport: URL(fileURLWithPath: "/tmp/x.consensus.json"),
            engines: ["a", "b", "c"], skipped: [:],
            estimate: ConsensusEstimate(adjudicator: "ds-lite", items: [],
                                        agreement: [:],
                                        diagnostics: AdjudicatorDiagnostics()),
            runID: "run-1", overwrote: false,
            singleConsensus: check)
    }

    @Test func renderShowsPassedSingleConsensusWithRatio() {
        let check = SingleConsensusCheck(
            verdict: .passed(ratio: 5.23, loadings: ["a": 0.7, "b": 0.7, "c": 0.2]),
            excluded: [])
        let text = BestOCRMCPServer.renderConsensusSummary(summaryFixture(check: check))
        #expect(text.contains("single-consensus: passed — eigenvalue ratio 5.23"))
    }

    @Test func renderShowsUntestableVerdictAndExclusions() {
        // untestable ≠ passed: the disclosure must be visible, with the
        // excluded engines named (absence of evidence, disclosed).
        let check = SingleConsensusCheck(
            verdict: .untestable(reason: "only 2 engine(s) with co-answer data "
                                     + "— the single-consensus check needs ≥ 3"),
            excluded: ["tesseract"])
        let text = BestOCRMCPServer.renderConsensusSummary(summaryFixture(check: check))
        #expect(text.contains("single-consensus: untestable — only 2 engine(s)"))
        #expect(text.contains("excluded: tesseract"))
    }

    @Test func renderOmitsSingleConsensusWhenCheckAbsent() {
        // majority / rover / legacy: no check ran — no line, never a verdict.
        let text = BestOCRMCPServer.renderConsensusSummary(summaryFixture(check: nil))
        #expect(!text.contains("single-consensus"))
    }
}
