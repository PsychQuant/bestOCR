import Foundation
import Testing
@testable import BestOCRKit

/// The pdftotext shred signature of a formula page (verbatim shape from #35):
/// operators swallowed, exponents drifting into isolated 1–2 char tokens.
private let formulaPageText = """
D x   q x( out)
(1  i ) 2
N x   Dx  t   v t
l x   d x   p x   q x
"""

private let prosePageText = """
The insurance policy provides comprehensive coverage for the policy holder
including hospitalization benefits and surgical allowances during the term
本保單提供住院醫療保險金與手術保險金之給付項目說明如下
"""

private func chars(_ n: Int) -> String {
    String(repeating: "字", count: n)
}

struct TriageProbeTests {

    private let config = TriageProbe.Config(textCharsMin: 200, fragmentRatioMax: 0.6)

    // MARK: - Task 1: per-page text-layer probe (1.2)

    @Test func bornDigitalAllPagesTextDirect() {
        let report = TriageProbe.measure(
            pages: [chars(1834), chars(1560)], config: config)
        #expect(report.pages.allSatisfy { $0.hasTextLayer })
        #expect(report.route == .textDirect)
        #expect(report.perPageRoutes == ["1": "text_direct", "2": "text_direct"])
        #expect(report.suspectPages.isEmpty)
    }

    @Test func scannedAllPagesOCRFull() {
        let report = TriageProbe.measure(
            pages: [chars(3), "", chars(12)], config: config)
        #expect(report.pages.allSatisfy { !$0.hasTextLayer })
        #expect(report.route == .ocrFull)
    }

    @Test func whitespaceDoesNotCountAsText() {
        let padded = String(repeating: "a \n\t", count: 60)  // 60 non-space chars
        let report = TriageProbe.measure(pages: [padded], config: config)
        #expect(report.pages[0].textChars == 60)
        #expect(report.pages[0].hasTextLayer == false)
    }

    /// Spec ##### Example: three-page hybrid — GIVEN counts [1834, 12, 1560]
    /// with text_chars_min = 200, THEN per_page_routes is exactly
    /// {"1": text_direct, "2": ocr_full, "3": text_direct} and route is mixed.
    @Test func hybridThreePageExample() {
        let report = TriageProbe.measure(
            pages: [chars(1834), chars(12), chars(1560)], config: config)
        #expect(report.perPageRoutes == [
            "1": "text_direct", "2": "ocr_full", "3": "text_direct",
        ])
        #expect(report.route == .mixed)
        // Text-bearing pages never routed to OCR; textless never to text_direct.
        #expect(report.perPageRoutes["2"] == "ocr_full")
    }

    // MARK: - Task 2: structure scan (1.3)

    @Test func formulaPageFlaggedSuspect() {
        let page = formulaPageText + "\n" + chars(200)  // text-bearing + shredded formulas
        let report = TriageProbe.measure(pages: [page], config: config)
        #expect(report.pages[0].hasTextLayer)
        #expect(report.pages[0].fragmentRatio > 0.6)
        #expect(report.suspectPages == [1])
        #expect(report.perPageRoutes["1"] == "render_suspect_pages")
        #expect(report.route == .renderSuspectPages)
    }

    @Test func prosePagePasses() {
        let page = prosePageText + chars(200)
        let report = TriageProbe.measure(pages: [page], config: config)
        #expect(report.pages[0].fragmentRatio <= 0.6)
        #expect(report.suspectPages.isEmpty)
        #expect(report.route == .textDirect)
    }

    @Test func suspectAndProseMixIsMixedRoute() {
        let formula = formulaPageText + "\n" + chars(200)
        let prose = prosePageText + chars(200)
        let report = TriageProbe.measure(pages: [prose, formula], config: config)
        #expect(report.route == .mixed)
        #expect(report.perPageRoutes == [
            "1": "text_direct", "2": "render_suspect_pages",
        ])
        #expect(report.suspectPages == [2])
    }

    @Test func fragmentRatioIgnoresShortLines() {
        // Lines with ≤3 tokens (e.g. "105 x") are not qualifying lines — a page
        // of short labels alone must not trip the suspect flag.
        let page = Array(repeating: "105 x", count: 50).joined(separator: "\n") + chars(200)
        let report = TriageProbe.measure(pages: [page], config: config)
        #expect(report.pages[0].fragmentRatio == 0)
        #expect(report.suspectPages.isEmpty)
    }

    // MARK: - Thresholds & env overrides

    @Test func thresholdsReportEffectiveValues() {
        let custom = TriageProbe.Config(textCharsMin: 500, fragmentRatioMax: 0.4)
        let report = TriageProbe.measure(pages: [chars(300)], config: custom)
        #expect(report.thresholds.textCharsMin == 500)
        #expect(report.thresholds.fragmentRatioMax == 0.4)
        #expect(report.pages[0].hasTextLayer == false)  // 300 < 500
    }

    @Test func configFromEnvironmentOverrides() {
        let env = ["BESTOCR_TRIAGE_TEXT_MIN": "350", "BESTOCR_TRIAGE_FRAG_MAX": "0.45"]
        let config = TriageProbe.Config.fromEnvironment(env)
        #expect(config.textCharsMin == 350)
        #expect(config.fragmentRatioMax == 0.45)
    }

    @Test func configFromEnvironmentDefaults() {
        let config = TriageProbe.Config.fromEnvironment([:])
        #expect(config.textCharsMin == 200)
        #expect(config.fragmentRatioMax == 0.6)
    }

    @Test func configIgnoresGarbageEnvValues() {
        let env = ["BESTOCR_TRIAGE_TEXT_MIN": "banana", "BESTOCR_TRIAGE_FRAG_MAX": "-3"]
        let config = TriageProbe.Config.fromEnvironment(env)
        #expect(config.textCharsMin == 200)   // non-numeric → default
        #expect(config.fragmentRatioMax == 0.6)  // out of (0, 1] → default
    }

    // MARK: - Task 1.4: explicit degradation without poppler

    @Test func missingPdftotextDegradesExplicitly() throws {
        let report = TriageProbe.run(inputPath: "/nonexistent/file.pdf",
                                     config: config, locator: { nil })
        let degraded = try #require(report.degraded)
        #expect(degraded.reason.contains("pdftotext"))
        #expect(degraded.installHint == "brew install poppler")
        #expect(report.route == .ocrFull)
        #expect(report.pages.isEmpty)
        #expect(report.divergence == nil)
    }

    @Test func imageInputSkipsProbeWithoutDegrading() {
        // Images have no text layer by definition — no pdftotext involved, so
        // a missing tool must NOT degrade the report.
        let report = TriageProbe.run(inputPath: "/nonexistent/shot.png",
                                     config: config, locator: { nil })
        #expect(report.degraded == nil)
        #expect(report.route == .ocrFull)
        #expect(report.pages.count == 1)
        #expect(report.pages[0].hasTextLayer == false)
    }
}
