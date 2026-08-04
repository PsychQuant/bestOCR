import Foundation
import Testing
@testable import BestOCRKit

/// The write path must carry a version; the read path must stay tolerant of
/// rows written before it existed (engine-version-provenance spec).
struct ConditionVersionWritePathTests {

    private static func condition(toolVersion: String?) -> ConditionTuple {
        ConditionTuple(model: "m", quant: "n/a", dpi: 300, docType: "scan",
                       platform: "p", hardware: "h",
                       instrument: BestOCRVersion.string, toolVersion: toolVersion)
    }

    // MARK: - Write path

    /// Vision is the one engine guaranteed present on every supported machine,
    /// so it is the honest end-to-end check that recognition emits a version.
    @Test("Recognition writes a version into the condition")
    func recognitionCarriesVersion() async throws {
        let image = try Fixtures.textImage("hello")
        let request = OCRRequest(pages: [PageImage(pageNumber: 1, url: image)],
                                 languages: ["en"], dpi: 300, docType: "scan")
        let result = try await VisionEngine().recognize(request)
        #expect(result.condition.toolVersion != nil)
    }

    // MARK: - Consensus path

    /// A consensus row is produced by several engines, so naming only one of
    /// them would misattribute the output.
    @Test("Consensus merges every member version")
    func consensusMergesMemberVersions() {
        let results = [
            "a": OCRResult(engineID: "a", pages: [],
                           condition: Self.condition(toolVersion: "surya 0.22.1")),
            "b": OCRResult(engineID: "b", pages: [],
                           condition: Self.condition(toolVersion: "tesseract 5.3.4")),
        ]
        let merged = RunLogEntry.mergedToolVersion(ids: ["a", "b"], results: results)
        let text = try! #require(merged)
        #expect(text.contains("surya 0.22.1"))
        #expect(text.contains("tesseract 5.3.4"))
    }

    /// A member with no version is left out rather than represented by a
    /// placeholder that would read as a real value.
    @Test("Consensus omits members that have no version")
    func consensusOmitsVersionlessMembers() {
        let results = [
            "a": OCRResult(engineID: "a", pages: [],
                           condition: Self.condition(toolVersion: "surya 0.22.1")),
            "b": OCRResult(engineID: "b", pages: [],
                           condition: Self.condition(toolVersion: nil)),
        ]
        let text = try! #require(RunLogEntry.mergedToolVersion(ids: ["a", "b"], results: results))
        #expect(text.contains("surya 0.22.1"))
        #expect(!text.contains("unknown"))
        #expect(!text.contains("b="))
    }

    @Test("Consensus with no versioned member stays unknown")
    func consensusAllUnknownStaysNil() {
        let results = [
            "a": OCRResult(engineID: "a", pages: [],
                           condition: Self.condition(toolVersion: nil)),
        ]
        #expect(RunLogEntry.mergedToolVersion(ids: ["a"], results: results) == nil)
    }

    // MARK: - Read path (backward compatibility)

    /// Rows archived before this change have no version field at all. They must
    /// keep decoding, and their version must stay unknown rather than being
    /// reconstructed from anything else in the row.
    @Test("A row archived without a version still decodes")
    func archivedRowWithoutVersionDecodes() throws {
        let archived = """
        {"model":"vision","quant":"n/a","dpi":300,"doc_type":"scan",
         "platform":"vision","hardware":"apple-m1","instrument":"bestocr 0.9.0"}
        """
        let data = try #require(archived.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ConditionTuple.self, from: data)
        #expect(decoded.toolVersion == nil)
        #expect(decoded.model == "vision")
    }

    @Test("A row written with a version round-trips")
    func versionedRowRoundTrips() throws {
        let original = Self.condition(toolVersion: "surya-ocr 0.22.1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConditionTuple.self, from: data)
        #expect(decoded.toolVersion == "surya-ocr 0.22.1")
    }
}
