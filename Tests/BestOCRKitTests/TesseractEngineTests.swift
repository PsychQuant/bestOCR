import Foundation
import Testing
@testable import BestOCRKit

struct TesseractEngineTests {
    @Test func identity() {
        let engine = TesseractEngine()
        #expect(engine.id == "tesseract")
        #expect(engine.family == .classical)
        #expect(engine.capabilities.needsNetwork == false)
    }

    @Test func languageMapping() {
        #expect(TesseractEngine.tesseractLanguages(["en"]) == "eng")
        #expect(TesseractEngine.tesseractLanguages(["zh-Hant", "ja"]) == "chi_tra+jpn")
        #expect(TesseractEngine.tesseractLanguages([]) == "eng")
        #expect(TesseractEngine.tesseractLanguages(["xx"]) == "eng")   // unknown → fallback
    }

    @Test func missingBinaryProbesUnavailableWithHint() async {
        let engine = TesseractEngine(binaryPath: "/nonexistent/tesseract")
        let availability = await engine.probe()
        guard case .unavailable(let reason, let hint) = availability else {
            Issue.record("expected unavailable, got \(availability)")
            return
        }
        #expect(reason.contains("tesseract"))
        #expect(hint == "brew install tesseract tesseract-lang")
    }

    // Integration: runs only when tesseract is actually installed (spec §9:
    // absent tool → visible skip, never fake-pass).
    @Test(.enabled(if: TesseractEngine.locate() != nil))
    func recognizesFixtureText() async throws {
        let engine = TesseractEngine()
        let img = try Fixtures.textImage("HELLO 42")
        let request = OCRRequest(pages: [PageImage(pageNumber: 1, url: img)],
                                 languages: ["en"], dpi: nil, docType: "screenshot")
        let result = try await engine.recognize(request)
        #expect(result.pages[0].text.contains("HELLO"))
        #expect(result.condition.platform == "tesseract")
    }
}
