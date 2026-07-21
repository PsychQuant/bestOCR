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
