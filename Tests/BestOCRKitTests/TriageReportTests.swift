import Foundation
import Testing
@testable import BestOCRKit

struct TriageReportTests {

    private func sampleReport(divergence: TriageReport.Divergence? = nil,
                              degraded: TriageReport.Degraded? = nil) -> TriageReport {
        TriageReport(
            pages: [
                .init(page: 1, textChars: 1834, hasTextLayer: true, fragmentRatio: 0.12, suspect: false),
                .init(page: 2, textChars: 12, hasTextLayer: false, fragmentRatio: 0, suspect: false),
            ],
            suspectPages: [],
            divergence: divergence,
            route: .mixed,
            perPageRoutes: ["1": "text_direct", "2": "ocr_full"],
            thresholds: .init(textCharsMin: 200, fragmentRatioMax: 0.6),
            degraded: degraded
        )
    }

    @Test func roundTripPreservesAllFields() throws {
        let original = sampleReport(
            divergence: .init(informants: ["pdftotext", "vision"], perPage: ["3": 0.82]),
            degraded: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TriageReport.self, from: data)
        #expect(decoded.pages.count == 2)
        #expect(decoded.pages[0].textChars == 1834)
        #expect(decoded.pages[0].hasTextLayer == true)
        #expect(decoded.route == .mixed)
        #expect(decoded.perPageRoutes["2"] == "ocr_full")
        #expect(decoded.divergence?.informants == ["pdftotext", "vision"])
        #expect(decoded.divergence?.perPage["3"] == 0.82)
        #expect(decoded.thresholds.textCharsMin == 200)
        #expect(decoded.degraded == nil)
    }

    /// Contract: divergence nil = "did not run" — the key must be ABSENT from
    /// JSON, never an empty object (P12 discipline: nil = no such concept).
    @Test func nilDivergenceOmitsKeyEntirely() throws {
        let data = try JSONEncoder().encode(sampleReport())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["divergence"] == nil)
        #expect(json["degraded"] == nil)
    }

    /// JSON keys are snake_case verbatim per the design contract — surfaces
    /// (CLI --json, MCP tool) must emit byte-identical field names.
    @Test func encodesSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(sampleReport())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["pages", "suspect_pages", "route", "per_page_routes", "thresholds"])
        let page = try #require((json["pages"] as? [[String: Any]])?.first)
        #expect(Set(page.keys) == ["page", "text_chars", "has_text_layer", "fragment_ratio", "suspect"])
        let thresholds = try #require(json["thresholds"] as? [String: Any])
        #expect(Set(thresholds.keys) == ["text_chars_min", "fragment_ratio_max"])
    }

    @Test func routeRawValuesMatchSpec() {
        #expect(TriageReport.Route.textDirect.rawValue == "text_direct")
        #expect(TriageReport.Route.renderSuspectPages.rawValue == "render_suspect_pages")
        #expect(TriageReport.Route.ocrFull.rawValue == "ocr_full")
        #expect(TriageReport.Route.mixed.rawValue == "mixed")
    }

    @Test func degradedCarriesReasonAndHint() throws {
        let report = sampleReport(degraded: .init(reason: "pdftotext not found",
                                                  installHint: "brew install poppler"))
        let data = try JSONEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let degraded = try #require(json["degraded"] as? [String: Any])
        #expect(degraded["reason"] as? String == "pdftotext not found")
        #expect(degraded["install_hint"] as? String == "brew install poppler")
    }

    /// The CLI's --json encoder settings (.prettyPrinted, .sortedKeys) must
    /// stay decode-compatible — the printed report IS the machine contract.
    @Test func cliJSONEncoderSettingsRoundTrip() throws {
        let original = sampleReport(
            divergence: .init(informants: ["pdftotext", "vision"], perPage: ["3": 0.82]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoded = try JSONDecoder().decode(TriageReport.self,
                                               from: try encoder.encode(original))
        #expect(decoded == original)
    }
}
