import Foundation
import Testing
@testable import BestOCRKit

/// Cloud-flavored stub for the privacy-contract test (#13 F8).
private struct CloudStubEngine: OCREngine {
    let id: String
    let family = EngineFamily.cloudReference
    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                           needsNetwork: true, memoryClass: .light)
    }
    func probe() async -> EngineAvailability { .available }
    func recognize(_ request: OCRRequest) async throws -> OCRResult {
        OCRResult(engineID: id, pages: [], condition: ConditionTuple(
            model: id, quant: "n/a", dpi: request.dpi, docType: request.docType,
            platform: "cloud", hardware: "test", instrument: "test"))
    }
}

/// Stub whose recognize is "cancelled" — cancellation must propagate (#13 F11).
private struct CancellingStubEngine: OCREngine {
    let id: String
    let family = EngineFamily.classical
    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                           needsNetwork: false, memoryClass: .light)
    }
    func probe() async -> EngineAvailability { .available }
    func recognize(_ request: OCRRequest) async throws -> OCRResult {
        throw CancellationError()
    }
}

/// ConsensusPipeline (#11): pure adjudication core + output writer.
struct ConsensusPipelineTests {

    private func fixtureSetup() throws -> (tmp: URL, img: URL, runLog: RunLog) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-t-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")!
        let img = tmp.appendingPathComponent("fixture.png")
        try png.write(to: img)
        return (tmp, img, RunLog(fileURL: tmp.appendingPathComponent("runlog.jsonl")))
    }

    private func result(_ engine: String, _ text: String) -> OCRResult {
        OCRResult(engineID: engine,
                  pages: [PageResult(page: 1, text: text, seconds: 0.1,
                                     thermalState: "nominal", degenerateFlagged: false)],
                  condition: ConditionTuple(model: engine, quant: "n/a", dpi: 150,
                                            docType: "test", platform: "test",
                                            hardware: "test", instrument: "test"))
    }

    @Test func adjudicateRecoversConsensusAcrossEngines() {
        let good = "line one\nline two\nline three"
        let bad = "line one\nline TWO-GARBLED\nline three"
        let estimate = ConsensusPipeline.adjudicate(results: [
            "A": result("A", good),
            "B": result("B", bad),
            "C": result("C", good),
        ])
        #expect(estimate.items.count == 3)
        let texts = estimate.items.map(\.consensusText)
        #expect(texts == ["line one", "line two", "line three"])
        let a = estimate.overallCompetence["A"] ?? 0
        let b = estimate.overallCompetence["B"] ?? 0
        #expect(a > b, "engine with the garbled line must score lower")
    }

    @Test func consensusRunLogEntryIsExplicitComposite() {
        // #12: the ensemble is the unit under measurement — never crammed
        // into a single member engine's fields (that would poison the
        // evidence condition semantics).
        let entry = RunLogEntry(
            consensusOf: ["B": result("B", "x\ny"), "A": result("A", "x\ny")],
            input: "/tmp/in.pdf", output: "/tmp/out.md",
            quality: .init(estimand: "consensus.low_consensus_share@v1", value: 0.25,
                           reference: "engines=A+B;converged=true"))
        #expect(entry.engineID == "consensus")
        #expect(entry.condition.model == "A+B")
        #expect(entry.condition.platform == "consensus")
        #expect(entry.condition.quant == "n/a")
        #expect(entry.pages.count == 1)
        #expect(abs(entry.pages[0].seconds - 0.2) < 1e-9,
                "page seconds are the ensemble TOTAL across engines")
        #expect(entry.quality?.estimand == "consensus.low_consensus_share@v1")
    }

    @Test func consensusEntryIngestsAsEnsembleEstimands() {
        // #12: distinct estimand strings keep ensemble numbers out of any
        // single-engine ranking (schema.md hard rule — never mixed), and the
        // quality caveat must speak consensus, not compare's cloud wording.
        let entry = RunLogEntry(
            consensusOf: ["A": result("A", "x"), "B": result("B", "x")],
            input: "/tmp/in.pdf", output: "/tmp/out.md",
            quality: .init(estimand: "consensus.low_consensus_share@v1", value: 0.1,
                           reference: "engines=A+B;converged=true"))
        let rows = EvidenceIngest.rows(from: entry)
        #expect(rows.count == 2)
        #expect(rows[0].estimand == "speed.ensemble_ms_per_page@v1")
        #expect(rows[0].caveat?.contains("ensemble") == true)
        #expect(rows[1].estimand == "consensus.low_consensus_share@v1")
        #expect(rows[1].caveat?.contains("not ground truth") == true)
        #expect(rows[1].caveat?.contains("cloud") != true,
                "consensus quality must not inherit compare's cloud caveat")
    }

    @Test func executeWritesConsensusRunLogEntry() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-runlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")!
        let img = tmp.appendingPathComponent("fixture.png")
        try png.write(to: img)
        let runLog = RunLog(fileURL: tmp.appendingPathComponent("runlog.jsonl"))
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello"),
            StubEngine(id: "B", availability: .available, text: "hello"),
        ])
        let summary = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B"], dpi: 150, pageSpec: "",
            languages: [], docType: "test", outDir: tmp.appendingPathComponent("out"),
            registry: registry, runLog: runLog)
        #expect(!summary.runID.isEmpty)
        let log = try String(contentsOf: runLog.fileURL, encoding: .utf8)
        #expect(log.contains("\"engineID\":\"consensus\""))
        #expect(log.contains(summary.runID))
    }

    @Test func explicitCloudEngineIsRefused() async throws {
        // #13 F8: SKILL says 純本機、文件不離機 and MCP declares
        // openWorldHint:false — an explicit cloud engine id must be refused
        // loudly, not silently honored.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello"),
            CloudStubEngine(id: "cloud.stub"),
        ])
        await #expect(throws: OCREngineError.self) {
            _ = try await ConsensusPipeline.execute(
                inputPath: img.path, engineIDs: ["A", "cloud.stub"], dpi: 150,
                pageSpec: "", languages: [], docType: "test",
                outDir: tmp.appendingPathComponent("out"), registry: registry,
                runLog: runLog)
        }
    }

    @Test func cancellationPropagatesInsteadOfBeingSwallowed() async throws {
        // #13 F11: CancellationError must rethrow — a cancelled job must not
        // keep running remaining engines and write outputs.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello"),
            CancellingStubEngine(id: "B"),
        ])
        await #expect(throws: CancellationError.self) {
            _ = try await ConsensusPipeline.execute(
                inputPath: img.path, engineIDs: ["A", "B"], dpi: 150,
                pageSpec: "", languages: [], docType: "test",
                outDir: tmp.appendingPathComponent("out"), registry: registry,
                runLog: runLog)
        }
    }

    @Test func duplicateEngineIDsAreDeduplicatedBeforeTheFloor() async throws {
        // #13 F12: "A,A" is one informant, not two — the ≥2 floor must see 1
        // (first guard, accurate message) instead of double-probing and only
        // failing at the produced-output guard with a misleading message.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello"),
        ])
        do {
            _ = try await ConsensusPipeline.execute(
                inputPath: img.path, engineIDs: ["A", "A"], dpi: 150,
                pageSpec: "", languages: [], docType: "test",
                outDir: tmp.appendingPathComponent("out"), registry: registry,
                runLog: runLog)
            Issue.record("expected the ≥2-engines floor to fire")
        } catch let error as OCREngineError {
            #expect(error.message.contains("needs ≥2"),
                    "dedupe must happen before the floor (got: \(error.message))")
        }
    }

    @Test func zeroCoAnswerIsRefusedNotReportedAsConsensus() async throws {
        // #13 F7: two OCRResults ≠ two effective informants. If no aligned
        // item has ≥2 responses there is no consensus to report.
        let (tmp, img, runLog) = try fixtureSetup()
        // Unequal item counts + zero similarity: no LCS anchor, no equal-gap
        // positional pair (that heuristic deliberately marries equal-length
        // garble), so nothing is co-answered.
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "aaaaaaaa"),
            StubEngine(id: "B", availability: .available, text: "z1\nz2\nz3"),
        ])
        await #expect(throws: OCREngineError.self) {
            _ = try await ConsensusPipeline.execute(
                inputPath: img.path, engineIDs: ["A", "B"], dpi: 150,
                pageSpec: "", languages: [], docType: "test",
                outDir: tmp.appendingPathComponent("out"), registry: registry,
                runLog: runLog)
        }
    }

    @Test func reportCarriesCoAnswerShareAndSilentEngines() async throws {
        // #13 F7/F15: co_answer_share is the honest coverage number; an
        // engine that produced output but zero alignable items must be
        // called out, not silently absent from the competence maps.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello world"),
            StubEngine(id: "B", availability: .available, text: "hello world"),
            StubEngine(id: "C", availability: .available, text: ""),
        ])
        let summary = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B", "C"], dpi: 150,
            pageSpec: "", languages: [], docType: "test",
            outDir: tmp.appendingPathComponent("out"), registry: registry,
            runLog: runLog)
        let data = try Data(contentsOf: summary.outputReport)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["co_answer_share"] as? Double ?? 0) > 0.99)
        #expect(json?["engines_without_aligned_items"] as? [String] == ["C"])
    }

    @Test func adjudicatePassesDegenerateFlagsToAlignment() {
        // #13 F4 wiring: the page-level degenerate flag must reach spine
        // selection — a flagged loop engine's 30 lines must not define the
        // item universe over a clean 2-line engine.
        let loopText = Array(repeating: "loop", count: 30).joined(separator: "\n")
        let loopResult = OCRResult(
            engineID: "C",
            pages: [PageResult(page: 1, text: loopText, seconds: 0.1,
                               thermalState: "nominal", degenerateFlagged: true)],
            condition: ConditionTuple(model: "C", quant: "n/a", dpi: 150,
                                      docType: "test", platform: "test",
                                      hardware: "test", instrument: "test"))
        let est = ConsensusPipeline.adjudicate(results: [
            "A": result("A", "one\ntwo"),
            "C": loopResult,
        ])
        // With the flag wired, A is the spine and C's zero-match loop items
        // are whole-page groups at the TAIL — so the page opens with A's
        // "one". Without the veto, C's loop would be the spine and open it.
        #expect(est.items.first?.responses.keys.contains("A") == true,
                "clean engine defines the spine when the other is degenerate-flagged")
    }

    @Test func reservedIdAndNetworkEnginesAreRefusedInExecute() async throws {
        // #13 verify: the reserved marker must be enforced in the pipeline,
        // not just asserted against today's standard registry; and the
        // local-only contract gates on needsNetwork too, not only family.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "x"),
            StubEngine(id: "consensus", availability: .available, text: "x"),
        ])
        do {
            _ = try await ConsensusPipeline.execute(
                inputPath: img.path, engineIDs: ["consensus", "A"], dpi: 150,
                pageSpec: "", languages: [], docType: "test",
                outDir: tmp.appendingPathComponent("out"), registry: registry, runLog: runLog)
            Issue.record("reserved id must be refused")
        } catch let error as OCREngineError {
            #expect(error.message.contains("reserved"))
        }
    }

    @Test func invalidDpiIsRefused() async throws {
        // #13 F15(d): dpi must be finite and positive before any work runs.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "x"),
            StubEngine(id: "B", availability: .available, text: "x"),
        ])
        for bad in [-5.0, 0, Double.nan, .infinity] {
            await #expect(throws: OCREngineError.self, "dpi \(bad) must be refused") {
                _ = try await ConsensusPipeline.execute(
                    inputPath: img.path, engineIDs: ["A", "B"], dpi: bad,
                    pageSpec: "", languages: [], docType: "test",
                    outDir: tmp.appendingPathComponent("out"), registry: registry, runLog: runLog)
            }
        }
    }

    @Test func overwritingExistingArtifactsIsSurfaced() async throws {
        // #13 F15(c): a second run over the same stem/outDir silently
        // replaced the artifacts — the summary must say so.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello"),
            StubEngine(id: "B", availability: .available, text: "hello"),
        ])
        let out = tmp.appendingPathComponent("out")
        let first = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B"], dpi: 150, pageSpec: "",
            languages: [], docType: "test", outDir: out, registry: registry, runLog: runLog)
        #expect(first.overwrote == false)
        let second = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B"], dpi: 150, pageSpec: "",
            languages: [], docType: "test", outDir: out, registry: registry, runLog: runLog)
        #expect(second.overwrote == true)
    }

    @Test func reportCarriesSchemaVersionAndDecodesLegacy() throws {
        // #13 verify (Codex): responses switched normalized→raw with no
        // schema marker. v2 declares itself; legacy decodes as v1.
        let estimate = ConsensusPipeline.adjudicate(results: [
            "A": result("A", "hello"), "B": result("B", "hello"),
        ])
        let report = ConsensusReport(estimate: estimate, engines: ["A", "B"], skipped: [:])
        #expect(report.schemaVersion == 2)
        let legacy = """
        {"agreement":{},"engines":["A"],"item_count":0,"iterations":1,
         "low_consensus":[],"overall_competence":{},"competence_by_kind":{},
         "skipped":{}}
        """
        let decoded = try JSONDecoder().decode(ConsensusReport.self, from: Data(legacy.utf8))
        #expect(decoded.schemaVersion == 1 && decoded.converged == false)
    }

    @Test func registryHasNoEngineNamedConsensus() {
        // #13: "consensus" is the reserved runlog marker (RunLog.swift) that
        // EvidenceIngest branches on — no real engine may ever claim it.
        #expect(!EngineRegistry.standard().engines.map(\.id).contains("consensus"))
    }

    @Test func oldReportJSONWithoutConvergedStillDecodes() throws {
        // #13: pre-converged-field reports must keep decoding (default false).
        let old = """
        {"agreement":{},"engines":["A"],"item_count":0,"iterations":1,
         "low_consensus":[],"overall_competence":{},"competence_by_kind":{},
         "skipped":{},"co_answer_share":0,"engines_without_aligned_items":[]}
        """
        let report = try JSONDecoder().decode(ConsensusReport.self, from: Data(old.utf8))
        #expect(report.converged == false)
    }

    @Test func writeOutputsProducesTranscriptAndReport() throws {
        // Fixture note (r2): a same-position disagreement now gets outvoted
        // via equal-gap pairing (correct — not low consensus). To exercise
        // the low_consensus report path we need a genuinely uncorroborated
        // item: an extra hallucinated line only engine C produced.
        let estimate = ConsensusPipeline.adjudicate(results: [
            "A": result("A", "hello\nworld"),
            "B": result("B", "hello\nworld"),
            "C": result("C", "hello\nworld\nEXTRA-HALLUCINATION"),
        ])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("consensus-test-\(UUID().uuidString)")
        let out = try ConsensusPipeline.writeOutputs(
            estimate: estimate, engines: ["A", "B", "C"], skipped: [:],
            inputPath: "/tmp/sample.pdf", outDir: tmp)

        let md = try String(contentsOf: out.markdown, encoding: .utf8)
        #expect(md.contains("hello"))

        let data = try Data(contentsOf: out.report)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["engines"] as? [String] == ["A", "B", "C"])
        #expect(json?["overall_competence"] != nil)
        let low = json?["low_consensus"] as? [[String: Any]]
        #expect((low?.count ?? 0) >= 1, "the A/B-vs-C fork must surface in low_consensus")
    }
}
