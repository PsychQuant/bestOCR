import Foundation
import Testing
@testable import BestOCRKit

/// Phase 0 of the document-assembly spec
/// (`docs/superpowers/specs/2026-07-28-document-assembly-engines.md`):
/// the result shape gains an OPTIONAL structural payload, so nothing already
/// written to disk may stop decoding.
struct DocumentStructureTests {
    // MARK: - Decode compatibility (the one genuinely dangerous edit)

    /// A `*.meta.json` archived before this change has no `document` key.
    @Test func legacyResultJSONStillDecodesWithNilDocument() throws {
        let legacy = """
        {"condition":{"doc_type":"math_pdf","dpi":100,"hardware":"test",
        "instrument":"bestocr 0.6.2","model":"glm-ocr","platform":"ollama",
        "quant":"q8_0"},"engineID":"vlm.glm-ocr",
        "pages":[{"degenerateFlagged":false,"page":1,"seconds":1.5,
        "text":"hello","thermalState":"nominal"}]}
        """
        let result = try JSONDecoder().decode(OCRResult.self, from: Data(legacy.utf8))
        #expect(result.document == nil)
        #expect(result.text == "hello")
    }

    /// The committed evidence rows are the schema's own record; a change to the
    /// condition tuple would break them silently.
    @Test func committedEvidenceRowsStillDecode() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BestOCRKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let rowsURL = repoRoot.appendingPathComponent("evidence/rows.jsonl")
        guard let content = try? String(contentsOf: rowsURL, encoding: .utf8) else {
            print("SKIP: evidence/rows.jsonl not readable at \(rowsURL.path)")
            return
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(!lines.isEmpty)
        for line in lines {
            _ = try JSONDecoder().decode(EvidenceRow.self, from: Data(line.utf8))
        }
    }

    /// An adapter that reports a block label we have never seen must not make a
    /// whole archived result undecodable — `.other` is in the vocabulary for
    /// exactly this.
    @Test func unknownBlockKindDecodesAsOther() throws {
        let json = #"{"page":1,"kind":"marginalia","text":"x"}"#
        let block = try JSONDecoder().decode(DocumentBlock.self, from: Data(json.utf8))
        #expect(block.kind == .other)
        #expect(block.bbox == nil)
    }

    // MARK: - Reading order

    /// Spec §4.2: reading order IS the array order — no separate index.
    @Test func structureTextJoinsBlocksInArrayOrder() {
        let structure = DocumentStructure(blocks: [
            DocumentBlock(page: 1, kind: .heading, text: "Title"),
            DocumentBlock(page: 1, kind: .paragraph, text: "Body"),
        ])
        #expect(structure.text == "Title\n\nBody")
    }

    // MARK: - §4.3 invariant

    static func result(pageTexts: [String], blockTexts: [String]) -> OCRResult {
        let pages = pageTexts.enumerated().map {
            PageResult(page: $0.offset + 1, text: $0.element, seconds: 0.1,
                       thermalState: "nominal", degenerateFlagged: false)
        }
        let blocks = blockTexts.map {
            DocumentBlock(page: 1, kind: .paragraph, text: $0)
        }
        let condition = ConditionTuple(model: "m", quant: "n/a", dpi: nil,
                                       docType: "multicolumn_scan", platform: "python",
                                       hardware: "test", instrument: "test")
        return OCRResult(engineID: "doc.stub", pages: pages, condition: condition,
                         document: DocumentStructure(blocks: blocks))
    }

    /// Same content, deliberately different order — that is the whole point of
    /// an assembly engine, so the invariant must accept it.
    @Test func invariantAcceptsReorderedSameContent() {
        let result = Self.result(pageTexts: ["header\nquestion one"],
                                 blockTexts: ["question one", "header"])
        #expect(result.documentContentMatchesPages)
    }

    /// A broken adapter that drops a block is what this invariant exists to catch.
    @Test func invariantRejectsDroppedContent() {
        let result = Self.result(pageTexts: ["header\nquestion one"],
                                 blockTexts: ["header"])
        #expect(!result.documentContentMatchesPages)
    }

    /// Whitespace and blank lines are formatting, not content.
    @Test func invariantIgnoresWhitespaceOnlyDifferences() {
        let result = Self.result(pageTexts: ["  header \n\n question   one\n"],
                                 blockTexts: ["header", "question one"])
        #expect(result.documentContentMatchesPages)
    }

    /// Per-page engines have nothing to check and must not be reported broken.
    @Test func invariantIsVacuouslyTrueWithoutStructure() {
        let condition = ConditionTuple(model: "m", quant: "n/a", dpi: nil,
                                       docType: "screenshot", platform: "stub",
                                       hardware: "test", instrument: "test")
        let result = OCRResult(engineID: "vision",
                               pages: [PageResult(page: 1, text: "x", seconds: 0.1,
                                                  thermalState: "nominal",
                                                  degenerateFlagged: false)],
                               condition: condition)
        #expect(result.documentContentMatchesPages)
    }
}
