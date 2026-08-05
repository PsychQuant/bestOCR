import Foundation
import Testing
@testable import BestOCRKit

/// Cloud-flavored stub for the privacy-contract test (#13 F8).
private struct CloudStubEngine: OCREngine {
    /// Stub drives no real tool, so the absence case is the honest answer.
    func resolveVersion() async -> EngineVersion { .unavailable }

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

/// Local family but network-reaching — the privacy gate must refuse it too.
private struct NetworkStubEngine: OCREngine {
    /// Stub drives no real tool, so the absence case is the honest answer.
    func resolveVersion() async -> EngineVersion { .unavailable }

    let id: String
    let family = EngineFamily.classical
    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText, languages: ["en"],
                           needsNetwork: true, memoryClass: .light)
    }
    func probe() async -> EngineAvailability { .available }
    func recognize(_ request: OCRRequest) async throws -> OCRResult {
        OCRResult(engineID: id, pages: [], condition: ConditionTuple(
            model: id, quant: "n/a", dpi: request.dpi, docType: request.docType,
            platform: "net", hardware: "test", instrument: "test"))
    }
}

/// Stub whose recognize is "cancelled" — cancellation must propagate (#13 F11).
private struct CancellingStubEngine: OCREngine {
    /// Stub drives no real tool, so the absence case is the honest answer.
    func resolveVersion() async -> EngineVersion { .unavailable }

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
        let a = estimate.diagnostics.overallCompetence?["A"] ?? 0
        let b = estimate.diagnostics.overallCompetence?["B"] ?? 0
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
        // #13 F7 → upgraded by #38: two OCRResults ≠ two effective informants.
        // Zero co-answered items used to THROW; the co-answer gate now returns
        // an explicit refused report instead — same protection, but the caller
        // gets the alignment diagnostics rather than a bare error (a refusal
        // is a measurement outcome, not a tool failure).
        let (tmp, img, runLog) = try fixtureSetup()
        // Unequal item counts + zero similarity: no LCS anchor, no equal-gap
        // positional pair (that heuristic deliberately marries equal-length
        // garble), so nothing is co-answered.
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "aaaaaaaa"),
            StubEngine(id: "B", availability: .available, text: "z1\nz2\nz3"),
        ])
        let summary = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B"], dpi: 150,
            pageSpec: "", languages: [], docType: "test",
            outDir: tmp.appendingPathComponent("out"), registry: registry,
            runLog: runLog)
        #expect(summary.refused)
        #expect(summary.refusalReason?.contains("co_answer_share") == true)
        #expect(summary.estimate.diagnostics.overallCompetence == nil)  // no estimator ran
        // The refused report file carries the diagnostics.
        let data = try Data(contentsOf: summary.outputReport)
        let report = try JSONDecoder().decode(ConsensusReport.self, from: data)
        #expect(report.refused)
        #expect(report.overallCompetence == nil)
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

        let netRegistry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "x"),
            NetworkStubEngine(id: "remote.vlm"),
        ])
        do {
            _ = try await ConsensusPipeline.execute(
                inputPath: img.path, engineIDs: ["A", "remote.vlm"], dpi: 150,
                pageSpec: "", languages: [], docType: "test",
                outDir: tmp.appendingPathComponent("out2"), registry: netRegistry, runLog: runLog)
            Issue.record("network-reaching engine must be refused")
        } catch let error as OCREngineError {
            #expect(error.message.contains("network") || error.message.contains("cloud"))
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

        // Report-only leftover (md removed) must still be surfaced.
        try FileManager.default.removeItem(at: second.outputMarkdown)
        let third = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B"], dpi: 150, pageSpec: "",
            languages: [], docType: "test", outDir: out, registry: registry, runLog: runLog)
        #expect(third.overwrote == true, "overwriting only the report is still overwriting")
    }

    @Test func reportCarriesSchemaVersionAndDecodesLegacy() throws {
        // #13 verify (Codex): responses switched normalized→raw with no
        // schema marker. v2 declares itself; legacy decodes as v1.
        let estimate = ConsensusPipeline.adjudicate(results: [
            "A": result("A", "hello"), "B": result("B", "hello"),
        ])
        let report = ConsensusReport(estimate: estimate, engines: ["A", "B"], skipped: [:])
        #expect(report.schemaVersion == 3)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(encoded.contains("\"schema_version\":3"), "the version must land in the JSON artifact")
        #expect(encoded.contains("\"adjudicator\":\"ds-lite\""),
                "#17: the artifact must name the model that produced it")
        let legacy = """
        {"agreement":{},"engines":["A"],"item_count":0,"iterations":1,
         "low_consensus":[],"overall_competence":{},"competence_by_kind":{},
         "skipped":{}}
        """
        let decoded = try JSONDecoder().decode(ConsensusReport.self, from: Data(legacy.utf8))
        #expect(decoded.schemaVersion == 1)
        // #17 changed this deliberately: a legacy file that never recorded
        // `converged` decodes as nil ("not recorded") rather than false
        // ("did not converge"). Defaulting to false asserted a fact the file
        // never contained.
        #expect(decoded.converged == nil)
        // Legacy reports predate pluggable adjudicators — ds-lite was the only
        // one that existed, so that is history, not an assumption.
        #expect(decoded.adjudicator == "ds-lite")
    }

    @Test func registryHasNoEngineNamedConsensus() {
        // #13: "consensus" is the reserved runlog marker (RunLog.swift) that
        // EvidenceIngest branches on — no real engine may ever claim it.
        #expect(!EngineRegistry.standard().engines.map(\.id).contains("consensus"))
    }

    @Test func oldReportJSONWithoutConvergedStillDecodes() throws {
        // #13: pre-converged-field reports must keep decoding. #17 changed the
        // absent value from `false` to `nil` — "not recorded" is not the same
        // claim as "did not converge", and only nil can say the former.
        let old = """
        {"agreement":{},"engines":["A"],"item_count":0,"iterations":1,
         "low_consensus":[],"overall_competence":{},"competence_by_kind":{},
         "skipped":{},"co_answer_share":0,"engines_without_aligned_items":[]}
        """
        let report = try JSONDecoder().decode(ConsensusReport.self, from: Data(old.utf8))
        #expect(report.converged == nil)
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

    // MARK: - #38: co-answer refusal gate + honest report shape

    private func soloHeavyItems() -> [AlignedItem] {
        // Reproduces the #38 shape: overwhelmingly single-engine items
        // (alignment never grouped the engines), a couple of co-answered ones.
        var items: [AlignedItem] = []
        for i in 0..<28 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["doc.marker": "cell-\(i)"]))
        }
        for i in 28..<30 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["vision": "line-\(i)", "ext.surya": "line-\(i)"]))
        }
        return items
    }

    @Test func coAnswerGateRefusesDegenerateAlignment() {
        let items = soloHeavyItems()
        let share = ConsensusPipeline.coAnswerShare(of: items)
        #expect(share < 0.2)
        let reason = ConsensusPipeline.coAnswerGate(items: items, threshold: 0.2)
        #expect(reason != nil)
        #expect(reason?.contains("co_answer_share") == true)
    }

    @Test func coAnswerGatePassesHealthyAlignment() {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["a": "x-\(i)", "b": "x-\(i)"]))
        }
        #expect(ConsensusPipeline.coAnswerGate(items: items, threshold: 0.2) == nil)
    }

    @Test func gateThresholdEnvOverrideWithGarbageProtection() {
        #expect(ConsensusPipeline.minCoAnswerThreshold(env: [:]) == 0.2)
        #expect(ConsensusPipeline.minCoAnswerThreshold(env: ["BESTOCR_CONSENSUS_MIN_COANSWER": "0.5"]) == 0.5)
        #expect(ConsensusPipeline.minCoAnswerThreshold(env: ["BESTOCR_CONSENSUS_MIN_COANSWER": "banana"]) == 0.2)
        #expect(ConsensusPipeline.minCoAnswerThreshold(env: ["BESTOCR_CONSENSUS_MIN_COANSWER": "-1"]) == 0.2)
        #expect(ConsensusPipeline.minCoAnswerThreshold(env: ["BESTOCR_CONSENSUS_MIN_COANSWER": "1.5"]) == 0.2)
    }

    @Test func refusedReportShapeKeepsDiagnosticsDropsCompetence() throws {
        let items = soloHeavyItems()
        let report = ConsensusReport.refused(items: items,
                                             engines: ["doc.marker", "vision", "ext.surya"],
                                             skipped: [:], adjudicator: "ds-lite",
                                             reason: "co_answer_share 0.067 below threshold 0.2")
        #expect(report.refused)
        #expect(report.refusalReason?.contains("co_answer_share") == true)
        #expect(report.overallCompetence == nil)       // no estimator ran — no competence
        #expect(report.iterations == nil)
        #expect(report.responseCounts?["1"] == 28)     // the 96.7%-style distribution
        #expect(report.responseCounts?["2"] == 2)
        #expect(report.coAnswerShare < 0.2)
        // Round-trip: refused shape survives encode/decode (additive fields).
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ConsensusReport.self, from: data)
        #expect(decoded.refused)
        #expect(decoded.responseCounts?["1"] == 28)
    }

    @Test func normalReportCarriesInformativeItemsAndResponseCounts() throws {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["a": "x-\(i)", "b": "x-\(i)"]))
        }
        let estimate = ConsensusEstimator.estimate(items: items)
        let report = ConsensusReport(estimate: estimate, engines: ["a", "b"], skipped: [:])
        #expect(report.refused == false)
        #expect(report.informativeItems?["a"] == 10)
        #expect(report.responseCounts?["2"] == 10)
        // Legacy decode: old report JSON without the new keys → refused=false, nils.
        let legacy = try JSONDecoder().decode(ConsensusReport.self, from: JSONEncoder().encode(report))
        #expect(legacy.refused == false)
    }

    // MARK: - #39: single-consensus validity gate

    /// The #39 observed shape at item level: {a,b} co-answer and agree,
    /// {c,d} co-answer and agree, and the two blocks never co-answer. Every
    /// item has 2 responses, so the #38 co-answer gate passes — this is the
    /// run the eigen check exists for.
    private func partitionedItems() -> [AlignedItem] {
        var items: [AlignedItem] = []
        for i in 0..<6 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["a": "x-\(i)", "b": "x-\(i)"]))
        }
        for i in 6..<12 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["c": "y-\(i)", "d": "y-\(i)"]))
        }
        return items
    }

    @Test func poolsRatersClassifiesAdjudicators() {
        // The criterion is the issue's own wording — "every adjudicator that
        // POOLS RATERS" under a single answer key — not "estimates
        // competence" (R1 renamed it: prior-weighted pools but reports no
        // per-engine competence, so the old name mislabeled the criterion).
        #expect(AdjudicatorRegistry.poolsRaters("ds-lite"))
        #expect(AdjudicatorRegistry.poolsRaters("ds-full"))
        #expect(AdjudicatorRegistry.poolsRaters("prior-weighted"))
        #expect(AdjudicatorRegistry.poolsRaters("irt"))
        // majority claims no competence model (no assumption to violate);
        // rover's confusion-network alignment is outside this check's reach
        // today — a KNOWN gap (#49), not a claim that rover lacks competence.
        #expect(!AdjudicatorRegistry.poolsRaters("majority"))
        #expect(!AdjudicatorRegistry.poolsRaters("rover"))
        #expect(!AdjudicatorRegistry.poolsRaters("no-such-adjudicator"))
    }

    @Test func partitionItemsRefuseWithRatioInReason() {
        let gate = ConsensusPipeline.singleConsensusGate(
            items: partitionedItems(), engines: ["a", "b", "c", "d"],
            adjudicatorID: "ds-lite")
        #expect(gate.refusalReason?.lowercased().contains("eigenvalue ratio") == true)
        #expect(gate.check?.verdict == "failed")
        // R1 F-04/F-05: a failed check must carry its numbers structurally —
        // the measured ratio AND the threshold that was in force.
        #expect(gate.check?.ratio != nil)
        #expect(gate.check?.minRatio == ConsensusValidity.minEigenRatio())
    }

    @Test func majorityGateSkipsEigenCheck() {
        // Issue Non-Goal: majority has no competence model, so there is no
        // single-key assumption to violate — nil check, not "passed".
        let gate = ConsensusPipeline.singleConsensusGate(
            items: partitionedItems(), engines: ["a", "b", "c", "d"],
            adjudicatorID: "majority")
        #expect(gate.refusalReason == nil)
        #expect(gate.check == nil)
    }

    @Test func healthyItemsPassGateWithCheckRecorded() {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["a": "x-\(i)", "b": "x-\(i)", "c": "x-\(i)"]))
        }
        let gate = ConsensusPipeline.singleConsensusGate(
            items: items, engines: ["a", "b", "c"], adjudicatorID: "ds-lite")
        #expect(gate.refusalReason == nil)
        #expect(gate.check?.verdict == "passed")
        #expect((gate.check?.ratio ?? 0) >= 3)
        #expect(gate.check?.ratio?.isFinite == true)
    }

    @Test func twoEngineGateIsUntestableNotSilent() {
        // Two co-answering engines cannot distinguish one culture from two.
        // The run proceeds, but "could not test" is disclosed — it must
        // never render as "tested and held".
        var items: [AlignedItem] = []
        for i in 0..<10 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["a": "x-\(i)", "b": "x-\(i)"]))
        }
        let gate = ConsensusPipeline.singleConsensusGate(
            items: items, engines: ["a", "b"], adjudicatorID: "ds-lite")
        #expect(gate.refusalReason == nil)
        #expect(gate.check?.verdict == "untestable")
    }

    @Test func reportRoundTripsSingleConsensusCheck() throws {
        var items: [AlignedItem] = []
        for i in 0..<10 {
            items.append(AlignedItem(key: ItemKey(page: 1, index: i, kind: .proseLine),
                                     responses: ["a": "x-\(i)", "b": "x-\(i)", "c": "x-\(i)"]))
        }
        let gate = ConsensusPipeline.singleConsensusGate(
            items: items, engines: ["a", "b", "c"], adjudicatorID: "ds-lite")
        let estimate = ConsensusEstimator.estimate(items: items)
        let report = ConsensusReport(estimate: estimate, engines: ["a", "b", "c"],
                                     skipped: [:], singleConsensus: gate.check)
        let decoded = try JSONDecoder().decode(ConsensusReport.self,
                                               from: JSONEncoder().encode(report))
        #expect(decoded.singleConsensus?.verdict == "passed")
        #expect((decoded.singleConsensus?.ratio ?? 0) >= 3)
        // JSON key is snake_case per report convention.
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(report)) as? [String: Any]
        #expect(json?["single_consensus"] != nil)
        // Legacy report without the key decodes to nil (absence = unchecked,
        // never a fabricated verdict).
        let legacyReport = ConsensusReport(estimate: estimate, engines: ["a", "b", "c"],
                                           skipped: [:])
        let legacy = try JSONDecoder().decode(ConsensusReport.self,
                                              from: JSONEncoder().encode(legacyReport))
        #expect(legacy.singleConsensus == nil)
    }

    @Test func eigenRefusedRunProducesRefusedReport() async throws {
        // Execute-level partition: two blocks of identical texts with
        // disjoint vocabulary and unequal line counts (no LCS anchor, no
        // equal-gap positional pair across blocks). Within-block co-answers
        // pass the #38 gate; the single-consensus check must refuse.
        //
        // FIXTURE DEPENDENCY: this relies on the aligner keeping the two
        // blocks un-co-answered. If alignment improves (#40 HTML cell-split
        // and successors), this fixture may stop producing a partition and
        // the test will fail as "not refused" — that is the FIXTURE
        // expiring, not the gate breaking; the behavior pin lives in the
        // unit-level partitionItemsRefuseWithRatioInReason.
        let (tmp, img, runLog) = try fixtureSetup()
        let blockOne = "alpha river\nbeta stone\ngamma cloud\ndelta forest"
        let blockTwo = "omega nine lanterns\nsigma quiet harbor\ntau winter map\n"
            + "rho copper bell\npi garden wall\nphi paper crane\nchi violet ink"
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: blockOne),
            StubEngine(id: "B", availability: .available, text: blockOne),
            StubEngine(id: "C", availability: .available, text: blockTwo),
            StubEngine(id: "D", availability: .available, text: blockTwo),
        ])
        let summary = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B", "C", "D"], dpi: 150,
            pageSpec: "", languages: [], docType: "test",
            outDir: tmp.appendingPathComponent("out"), registry: registry,
            runLog: runLog)
        #expect(summary.refused)
        #expect(summary.refusalReason?.lowercased().contains("single-consensus") == true)
        let data = try Data(contentsOf: summary.outputReport)
        let report = try JSONDecoder().decode(ConsensusReport.self, from: data)
        #expect(report.refused)
        #expect(report.overallCompetence == nil)
        #expect(report.singleConsensus?.verdict == "failed")
    }

    @Test func refusedRunReportsOverwrote() async throws {
        // R1 security M2: refusedRun unconditionally replaces
        // <stem>.consensus.* but hard-coded `overwrote: false` — a previous
        // VALID run's artifacts silently became two lines of refusal while
        // the tool claimed nothing was overwritten (#13 F15c violation).
        let (tmp, img, runLog) = try fixtureSetup()
        let outDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = img.deletingPathExtension().lastPathComponent
        try "previous valid transcript".write(
            to: outDir.appendingPathComponent("\(stem).consensus.md"),
            atomically: true, encoding: .utf8)
        let blockOne = "alpha river\nbeta stone\ngamma cloud\ndelta forest"
        let blockTwo = "omega nine lanterns\nsigma quiet harbor\ntau winter map\n"
            + "rho copper bell\npi garden wall\nphi paper crane\nchi violet ink"
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: blockOne),
            StubEngine(id: "B", availability: .available, text: blockOne),
            StubEngine(id: "C", availability: .available, text: blockTwo),
            StubEngine(id: "D", availability: .available, text: blockTwo),
        ])
        let summary = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B", "C", "D"], dpi: 150,
            pageSpec: "", languages: [], docType: "test",
            outDir: outDir, registry: registry, runLog: runLog)
        #expect(summary.refused)
        #expect(summary.overwrote)   // the pre-existing artifact WAS replaced
    }

    @Test func coAnswerRefusedReportOmitsSingleConsensusKey() throws {
        // Pin (R1 regression L2): when the check did not run (co-answer
        // refusal → nil), the JSON must not even carry the key — today this
        // is guaranteed only by synthesized encodeIfPresent; this test makes
        // that language-level accident an explicit contract.
        let report = ConsensusReport.refused(items: soloHeavyItems(),
                                             engines: ["doc.marker", "vision", "ext.surya"],
                                             skipped: [:], adjudicator: "ds-lite",
                                             reason: "co_answer_share 0.067 below threshold 0.2")
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(report)) as? [String: Any]
        // Guard the guard: optional-chaining flattens to Any?, so a failed
        // cast would also read as nil — assert the dictionary exists first
        // (R2 requirements N4).
        #expect(json != nil)
        #expect(json?["single_consensus"] == nil)
    }

    @Test func checkDecodesWithoutMinRatioOrUnboundedKeys() throws {
        // v1 → v2 migration pin (R2 regression R2-REG-7): a report written
        // before min_ratio / ratio_unbounded existed must decode with nil
        // for both — never throw, never fabricate.
        let legacy = #"{"verdict":"passed","ratio":5.2,"excluded_engines":[]}"#
        let check = try JSONDecoder().decode(SingleConsensusCheck.self,
                                             from: Data(legacy.utf8))
        #expect(check.minRatio == nil)
        #expect(check.ratioUnbounded == nil)
        #expect(check.ratio == 5.2)
    }

    @Test func untestableRunProceedsWithDisclosure() async throws {
        // Two agreeing engines: the run must NOT be refused (nothing wrong
        // with it), but the report must disclose the check was untestable.
        let (tmp, img, runLog) = try fixtureSetup()
        let registry = EngineRegistry(engines: [
            StubEngine(id: "A", availability: .available, text: "hello world"),
            StubEngine(id: "B", availability: .available, text: "hello world"),
        ])
        let summary = try await ConsensusPipeline.execute(
            inputPath: img.path, engineIDs: ["A", "B"], dpi: 150,
            pageSpec: "", languages: [], docType: "test",
            outDir: tmp.appendingPathComponent("out"), registry: registry,
            runLog: runLog)
        #expect(summary.refused == false)
        #expect(summary.singleConsensus?.verdict == "untestable")
        let data = try Data(contentsOf: summary.outputReport)
        let report = try JSONDecoder().decode(ConsensusReport.self, from: data)
        #expect(report.singleConsensus?.verdict == "untestable")
    }
}
