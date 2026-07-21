import Foundation
import Testing
@testable import BestOCRKit

struct EvidenceIngestTests {
    func entry(seconds: [Double], thermal: String = "nominal",
               quality: RunLogEntry.QualityStat? = nil) -> RunLogEntry {
        let condition = ConditionTuple(model: "vision", quant: "n/a", dpi: 150,
                                       docType: "screenshot", platform: "vision",
                                       hardware: "test", instrument: BestOCRVersion.string)
        let result = OCRResult(engineID: "vision",
                               pages: seconds.enumerated().map { index, secs in
                                   PageResult(page: index + 1, text: "x", seconds: secs,
                                              thermalState: thermal, degenerateFlagged: false)
                               }, condition: condition)
        return RunLogEntry(from: result, input: "/a.png", output: "/o.md", quality: quality)
    }

    @Test func speedRowFromMeanPageSeconds() {
        let rows = EvidenceIngest.rows(from: entry(seconds: [1.0, 3.0]))
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.estimand == "speed.ms_per_page")
        #expect(row.value == 2000)
        #expect(row.tier == "T2")
        #expect(row.source.hasPrefix("runlog:"))
        #expect(row.caveat == nil)
        #expect(row.condition.docType == "screenshot")
    }

    @Test func thermalCaveatWhenNotNominal() {
        let rows = EvidenceIngest.rows(from: entry(seconds: [1.0], thermal: "serious"))
        #expect(rows[0].caveat?.contains("serious") == true)
    }

    @Test func findEntryByUniquePrefixAndLoudFailures() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlog-\(UUID().uuidString).jsonl")
        let log = RunLog(fileURL: file)
        let e1 = entry(seconds: [1.0]); try log.append(e1)
        let e2 = entry(seconds: [2.0]); try log.append(e2)
        let found = try EvidenceIngest.findEntry(id: String(e1.id.prefix(8)), in: file)
        #expect(found.id == e1.id)
        #expect(throws: OCREngineError.self) {
            _ = try EvidenceIngest.findEntry(id: "zzzz-none", in: file)
        }
    }

    @Test func qualityStatYieldsAdditionalQualityRow() {
        let stat = RunLogEntry.QualityStat(estimand: Comparator.formulaID,
                                           value: 0.873,
                                           reference: "cloud.claude/claude-opus-4-8")
        let rows = EvidenceIngest.rows(from: entry(seconds: [1.0], quality: stat))
        #expect(rows.count == 2)
        let quality = rows[1]
        #expect(quality.estimand == "quality.token_recall_vs_cloud@v1")
        #expect(quality.value == 0.873)
        #expect(quality.tier == "T2")
        #expect(quality.source.hasPrefix("runlog:"))
        // Schema discipline: the referent must be named and disclaimed —
        // a cloud model output is not ground truth, never word_recall.
        #expect(quality.caveat?.contains("cloud.claude/claude-opus-4-8") == true)
        #expect(quality.caveat?.contains("not ground truth") == true)
        #expect(quality.condition.docType == "screenshot")
    }

    @Test func entryWithoutQualityStatYieldsSpeedRowOnly() {
        let rows = EvidenceIngest.rows(from: entry(seconds: [1.0]))
        #expect(rows.map(\.estimand) == ["speed.ms_per_page"])
    }

    @Test func appendWritesLoadableRows() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rows-\(UUID().uuidString).jsonl")
        try EvidenceIngest.append(EvidenceIngest.rows(from: entry(seconds: [1.5])), to: file)
        try EvidenceIngest.append(EvidenceIngest.rows(from: entry(seconds: [2.5])), to: file)
        let store = try EvidenceStore.load(from: file)
        #expect(store.rows.count == 2)
        #expect(store.rows.allSatisfy { $0.estimand == "speed.ms_per_page" })
    }
}
