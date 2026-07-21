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

    @Test func qualityStatRoundTripsAndOldLinesDecodeWithoutIt() throws {
        // Pre-quality runlog lines have no "quality" key — they must keep
        // decoding (quality == nil), and nil must keep encoding key-free so
        // old and new binaries read each other's logs.
        let plain = RunLogEntry(from: sampleResult(), input: "/a.pdf", output: "/o.md")
        let encoder = JSONEncoder()
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("\"quality\""))
        let decodedPlain = try JSONDecoder().decode(RunLogEntry.self,
                                                    from: Data(plainJSON.utf8))
        #expect(decodedPlain.quality == nil)

        let stat = RunLogEntry.QualityStat(estimand: Comparator.formulaID,
                                           value: 0.91,
                                           reference: "cloud.gemini/gemini-2.5-flash")
        let withQuality = RunLogEntry(from: sampleResult(), input: "/a.pdf",
                                      output: "/o.md", quality: stat)
        let decoded = try JSONDecoder().decode(RunLogEntry.self,
                                               from: try encoder.encode(withQuality))
        #expect(decoded.quality?.estimand == "quality.token_recall_vs_cloud@v1")
        #expect(decoded.quality?.value == 0.91)
        #expect(decoded.quality?.reference == "cloud.gemini/gemini-2.5-flash")
    }

    @Test func defaultHonoursEnvOverride() {
        setenv("BESTOCR_RUNLOG", "/tmp/custom-runlog.jsonl", 1)
        defer { unsetenv("BESTOCR_RUNLOG") }
        #expect(RunLog.default().fileURL.path == "/tmp/custom-runlog.jsonl")
    }
}
