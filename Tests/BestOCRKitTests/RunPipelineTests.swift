import Foundation
import Testing
@testable import BestOCRKit

/// Always-available engine whose recognize always throws — fallback fodder.
struct FailingEngine: OCREngine {
    let id: String
    let family = EngineFamily.classical
    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                           needsNetwork: false, memoryClass: .light)
    }
    func probe() async -> EngineAvailability { .available }
    func recognize(_ request: OCRRequest) async throws -> OCRResult {
        throw OCREngineError(engine: id, message: "boom")
    }
}

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

    @Test func autoFallsBackPastFailuresAndRecordsAttempts() async throws {
        let (outDir, runLog) = try makeEnv()
        let registry = EngineRegistry(engines: [
            FailingEngine(id: "broken"),
            StubEngine(id: "off", availability: .unavailable(reason: "not installed", installHint: nil), text: "x"),
            StubEngine(id: "works", availability: .available, text: "AUTO TEXT"),
        ])
        let img = try Fixtures.textImage("HELLO")
        let summary = try await RunPipeline.executeAuto(
            inputPath: img.path, dpi: 150, pageSpec: "", languages: [],
            docType: "screenshot", priority: .balanced, needsMath: false,
            outDir: outDir, registry: registry,
            evidence: EvidenceStore(rows: []), runLog: runLog)
        #expect(summary.result.engineID == "works")
        #expect(summary.attempts.map(\.engineID) == ["broken", "off", "works"])
        #expect(summary.attempts[0].failure?.contains("boom") == true)
        #expect(summary.attempts[1].failure?.contains("unavailable") == true)
        #expect(summary.attempts[2].failure == nil)
        let md = try String(contentsOf: summary.outputMarkdown, encoding: .utf8)
        #expect(md.contains("AUTO TEXT"))
    }

    @Test func autoAllFailListsEveryAttempt() async throws {
        let (outDir, runLog) = try makeEnv()
        let registry = EngineRegistry(engines: [
            FailingEngine(id: "b1"), FailingEngine(id: "b2"),
        ])
        let img = try Fixtures.textImage("X")
        do {
            _ = try await RunPipeline.executeAuto(
                inputPath: img.path, dpi: 150, pageSpec: "", languages: [],
                docType: "screenshot", priority: .balanced, needsMath: false,
                outDir: outDir, registry: registry,
                evidence: EvidenceStore(rows: []), runLog: runLog)
            Issue.record("expected throw")
        } catch let error as OCREngineError {
            #expect(error.message.contains("b1"))
            #expect(error.message.contains("b2"))
        }
    }

    @Test func autoRespectsEvidenceRanking() async throws {
        let (outDir, runLog) = try makeEnv()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "slow", availability: .available, text: "SLOW"),
            StubEngine(id: "fast", availability: .available, text: "FAST"),
        ])
        let evidence = EvidenceStore(rows: [
            EvidenceRow(estimand: "speed.ms_per_page", value: 9000,
                        condition: ConditionTuple(model: "slow", quant: "n/a", dpi: 150,
                                                  docType: "screenshot", platform: "stub",
                                                  hardware: "t", instrument: "t"),
                        tier: "T2", source: "s1"),
            EvidenceRow(estimand: "speed.ms_per_page", value: 100,
                        condition: ConditionTuple(model: "fast", quant: "n/a", dpi: 150,
                                                  docType: "screenshot", platform: "stub",
                                                  hardware: "t", instrument: "t"),
                        tier: "T2", source: "s2"),
        ])
        let img = try Fixtures.textImage("X")
        let summary = try await RunPipeline.executeAuto(
            inputPath: img.path, dpi: 150, pageSpec: "", languages: [],
            docType: "screenshot", priority: .speed, needsMath: false,
            outDir: outDir, registry: registry, evidence: evidence, runLog: runLog)
        #expect(summary.result.engineID == "fast")   // ranked by measured speed
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
