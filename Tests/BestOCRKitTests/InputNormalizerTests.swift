import Foundation
import Testing
@testable import BestOCRKit

struct InputNormalizerTests {
    @Test func parsePagesHandlesRangesAndSingles() {
        #expect(InputNormalizer.parsePages("1-3,5", count: 10) == [1, 2, 3, 5])
        #expect(InputNormalizer.parsePages("", count: 3) == [1, 2, 3])
        #expect(InputNormalizer.parsePages("2-99", count: 4) == [2, 3, 4])
        #expect(InputNormalizer.parsePages("7", count: 4) == [])
    }

    @Test func imagePassesThroughWithNilDPI() throws {
        let img = try Fixtures.textImage("HELLO 42")
        let normalized = try InputNormalizer.normalize(
            inputPath: img.path, dpi: 150, pageSpec: "", workDir: nil)
        defer { normalized.cleanup() }
        #expect(normalized.pages.count == 1)
        #expect(normalized.pages[0].pageNumber == 1)
        #expect(normalized.pages[0].url == img)
        #expect(normalized.dpi == nil)
        #expect(normalized.cleanupDir == nil)
    }

    @Test func pdfRendersRequestedPagesAtDPI() throws {
        let pdf = try Fixtures.textPDF("NORMALIZE", pages: 3)
        let normalized = try InputNormalizer.normalize(
            inputPath: pdf.path, dpi: 100, pageSpec: "1-2", workDir: nil)
        #expect(normalized.pages.count == 2)
        #expect(normalized.pages.map(\.pageNumber) == [1, 2])
        #expect(normalized.dpi == 100)
        for page in normalized.pages {
            #expect(FileManager.default.fileExists(atPath: page.url.path))
        }
        let dir = try #require(normalized.cleanupDir)
        normalized.cleanup()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func unknownExtensionThrows() {
        #expect(throws: OCREngineError.self) {
            _ = try InputNormalizer.normalize(
                inputPath: "/tmp/nope.docx", dpi: 150, pageSpec: "", workDir: nil)
        }
    }
}
