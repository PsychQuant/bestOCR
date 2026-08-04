import Foundation
import Testing
@testable import BestOCRKit

struct EngineVersionTests {
    private func roundTrip(_ value: EngineVersion) throws -> EngineVersion {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(EngineVersion.self, from: data)
    }

    @Test("A populated version survives encode and decode")
    func populatedRoundTrip() throws {
        let value = EngineVersion(components: ["surya-ocr": "0.22.1", "torch": "2.13.0"],
                                  resolution: .adapterReported)
        #expect(try roundTrip(value) == value)
    }

    /// Empty components with `.unavailable` is a legal value, not a degenerate
    /// one — it is how "no version information" is stated.
    @Test("An empty version survives encode and decode")
    func emptyRoundTrip() throws {
        #expect(try roundTrip(.unavailable) == EngineVersion.unavailable)
    }

    @Test("Every resolution case survives encode and decode")
    func everyResolutionRoundTrips() throws {
        for resolution in [VersionResolution.declared, .probed, .adapterReported, .unavailable] {
            let value = EngineVersion(components: ["x": "1"], resolution: resolution)
            #expect(try roundTrip(value).resolution == resolution)
        }
    }

    @Test("The absence case carries no components")
    func unavailableIsEmpty() {
        #expect(EngineVersion.unavailable.components.isEmpty)
        #expect(EngineVersion.unavailable.resolution == .unavailable)
    }

    /// The legacy string field means "unknown" when absent; an empty version
    /// must not manufacture a placeholder for it.
    @Test("An empty version yields no legacy string")
    func emptyYieldsNoLegacyString() {
        #expect(EngineVersion.unavailable.legacyToolVersion == nil)
    }

    @Test("Legacy string is stable regardless of dictionary ordering")
    func legacyStringIsOrdered() {
        let a = EngineVersion(components: ["torch": "2.13.0", "surya-ocr": "0.22.1"],
                              resolution: .adapterReported)
        let b = EngineVersion(components: ["surya-ocr": "0.22.1", "torch": "2.13.0"],
                              resolution: .adapterReported)
        #expect(a.legacyToolVersion == b.legacyToolVersion)
        #expect(a.legacyToolVersion == "surya-ocr 0.22.1; torch 2.13.0")
    }

    @Test("The single-component helper matches a hand-built value")
    func singleHelper() {
        let made = EngineVersion.single("tesseract", "5.3.4", resolution: .probed)
        #expect(made == EngineVersion(components: ["tesseract": "5.3.4"], resolution: .probed))
    }
}
