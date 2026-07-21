import Testing
@testable import BestOCRKit

/// Minimal stub for registry/recommender tests.
struct StubEngine: OCREngine {
    let id: String
    let family = EngineFamily.classical
    let availability: EngineAvailability
    let text: String
    var outputLevel: OutputLevel = .plainText

    var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: outputLevel, languages: ["en"],
                           needsNetwork: false, memoryClass: .light)
    }

    func probe() async -> EngineAvailability { availability }

    func recognize(_ request: OCRRequest) async throws -> OCRResult {
        let pages = request.pages.map {
            PageResult(page: $0.pageNumber, text: text, seconds: 0.01,
                       thermalState: "nominal", degenerateFlagged: false)
        }
        let condition = ConditionTuple(model: id, quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "stub",
                                       hardware: "test", instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pages, condition: condition)
    }
}

struct EngineRegistryTests {
    @Test func standardRosterHasEightEngines() {
        let registry = EngineRegistry.standard()
        #expect(registry.engines.map(\.id) ==
                ["vision", "tesseract", "ext.rapidocr", "ext.cnocr", "ext.surya",
                 "vlm.glm-ocr", "vlm.ovisocr2", "vlm.paddleocr-vl"])
    }

    @Test func lookupByIDAndUnknownReturnsNil() {
        let registry = EngineRegistry.standard()
        #expect(registry.engine(id: "vision") != nil)
        #expect(registry.engine(id: "nope") == nil)
    }

    @Test func probeAllPreservesOrderAndAvailability() async {
        let registry = EngineRegistry(engines: [
            StubEngine(id: "a", availability: .available, text: "x"),
            StubEngine(id: "b", availability: .unavailable(reason: "off", installHint: nil), text: "y"),
        ])
        let probed = await registry.probeAll()
        #expect(probed.map(\.engine.id) == ["a", "b"])
        #expect(probed[0].availability == .available)
        #expect(probed[1].availability == .unavailable(reason: "off", installHint: nil))
    }
}
