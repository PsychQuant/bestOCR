import Foundation
import Testing
@testable import BestOCRKit

struct CoreTypesTests {
    @Test func conditionTupleEncodesSchemaKeys() throws {
        let tuple = ConditionTuple(
            model: "glm-ocr", quant: "q4_K_M", dpi: 150,
            docType: "math_compiled", platform: "ollama",
            hardware: "Apple M5 Max, 128GB", instrument: BestOCRVersion.string
        )
        let data = try JSONEncoder().encode(tuple)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Keys must match evidence/schema.md §3 verbatim.
        #expect(Set(json.keys) == ["model", "quant", "dpi", "doc_type", "platform", "hardware", "instrument"])
        #expect(json["doc_type"] as? String == "math_compiled")
    }

    @Test func ocrResultJoinsPageText() {
        let condition = ConditionTuple(
            model: "vision", quant: "n/a", dpi: nil, docType: "unspecified",
            platform: "vision", hardware: "test", instrument: BestOCRVersion.string
        )
        let result = OCRResult(engineID: "vision", pages: [
            PageResult(page: 1, text: "one", seconds: 0.1, thermalState: "nominal", degenerateFlagged: false),
            PageResult(page: 2, text: "two", seconds: 0.1, thermalState: "nominal", degenerateFlagged: false),
        ], condition: condition)
        #expect(result.text == "one\n\ntwo")
    }

    @Test func hardwareLabelMentionsAppleAndMemory() {
        let label = HostInfo.hardwareLabel()
        #expect(label.contains("Apple"))
        #expect(label.contains("GB"))
    }
}
