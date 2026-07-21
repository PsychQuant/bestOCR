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

    @Test func defaultHonoursEnvOverride() {
        setenv("BESTOCR_RUNLOG", "/tmp/custom-runlog.jsonl", 1)
        defer { unsetenv("BESTOCR_RUNLOG") }
        #expect(RunLog.default().fileURL.path == "/tmp/custom-runlog.jsonl")
    }
}
