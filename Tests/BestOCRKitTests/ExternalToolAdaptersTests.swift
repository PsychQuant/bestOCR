import Foundation
import Testing
@testable import BestOCRKit

struct ExternalToolAdaptersTests {
    @Test func wiringIdentities() {
        #expect(ExternalToolEngine.cnocr().id == "ext.cnocr")
        #expect(ExternalToolEngine.surya().id == "ext.surya")
        #expect(ExternalToolEngine.cnocr().capabilities.languages.contains("zh-Hant"))
    }

    // Live integration — visible early-return skip when cnocr is absent.
    @Test func cnocrRecognizesFixture() async throws {
        let engine = ExternalToolEngine.cnocr()
        guard case .available = await engine.probe() else {
            print("SKIP: cnocr unavailable on this machine")
            return
        }
        let img = try Fixtures.textImage("HELLO 42")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], languages: ["en"], docType: "screenshot"))
        #expect(result.pages[0].text.uppercased().contains("HELLO"))
    }

    // surya downloads ~GB of models on first run — opt-in only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BESTOCR_TEST_SURYA"] != nil))
    func suryaRecognizesFixture() async throws {
        let engine = ExternalToolEngine.surya()
        guard case .available = await engine.probe() else {
            print("SKIP: surya unavailable on this machine")
            return
        }
        let img = try Fixtures.textImage("HELLO 42")
        let result = try await engine.recognize(OCRRequest(
            pages: [PageImage(pageNumber: 1, url: img)], languages: ["en"], docType: "screenshot"))
        #expect(result.pages[0].text.contains("HELLO"))
    }
}
