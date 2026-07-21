import Foundation
import Testing
@testable import BestOCRKit

struct VisionEngineTests {
    let engine = VisionEngine()

    @Test func identityAndCapabilities() {
        #expect(engine.id == "vision")
        #expect(engine.family == .classical)
        #expect(engine.capabilities.needsNetwork == false)
        #expect(engine.capabilities.outputLevel == .plainText)
    }

    @Test func probeIsAlwaysAvailable() async {
        #expect(await engine.probe() == .available)
    }

    @Test func recognizesFixtureText() async throws {
        let img = try Fixtures.textImage("HELLO 42")
        let request = OCRRequest(pages: [PageImage(pageNumber: 1, url: img)],
                                 languages: ["en"], dpi: nil, docType: "screenshot")
        let result = try await engine.recognize(request)
        #expect(result.engineID == "vision")
        #expect(result.pages.count == 1)
        #expect(result.pages[0].text.contains("HELLO"))
        #expect(result.condition.model == "vision")
        #expect(result.condition.quant == "n/a")
        #expect(result.condition.docType == "screenshot")
        #expect(result.pages[0].seconds > 0)
    }
}
