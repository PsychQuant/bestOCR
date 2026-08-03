import Foundation
import Testing
@testable import BestOCRKit

/// Divergence between extraction methods — the consensus estimator's insight
/// (disagreement IS the signal) reused with informants = extraction methods.
struct TriageDivergenceTests {

    /// pdftotext shred of a formula page vs what a visual reader sees:
    /// maximal, position-aligned disagreement (the #35 field observation).
    private let formulaPdftotext = """
    D x   q x( out)
    (1  i ) 2
    N x   Dx  t   v t
    l x   d x   p x   q x
    """
    private let formulaVision = """
    D_x × q_x^(out)
    (1+i)^(1/2)
    N_x = Σ D_(x+t) · v^t
    l_x − d_x = p_x + q_x
    """

    private let prose = """
    The insurance policy provides comprehensive coverage for the policy holder
    including hospitalization benefits and surgical allowances during the term
    of the contract as described in the following sections of this document
    with additional riders available upon request from the issuing office
    """

    @Test func formulaPageDivergesMoreThanProsePage() {
        let report = TriageDivergence.measure(
            pages: [1, 2],
            pdftotext: { page in page == 1 ? formulaPdftotext : prose },
            vision: { page in page == 1 ? formulaVision : prose })
        let formulaScore = report.perPage["1"]!
        let proseScore = report.perPage["2"]!
        #expect(formulaScore > proseScore)
        #expect(proseScore == 0)      // identical extractions — zero divergence
        #expect(formulaScore > 0.5)   // shredded operators disagree on most lines
        #expect(report.informants == ["pdftotext", "vision"])
    }

    @Test func emptyBothSidesIsZeroDivergence() {
        let report = TriageDivergence.measure(pages: [1], pdftotext: { _ in "" },
                                              vision: { _ in "" })
        #expect(report.perPage["1"] == 0)
    }

    @Test func oneSidedEmptyIsFullDivergence() {
        let report = TriageDivergence.measure(pages: [1], pdftotext: { _ in "" },
                                              vision: { _ in prose })
        #expect(report.perPage["1"] == 1)
    }

    // MARK: - enrich: suspect pages only (the "cheap triage" cost contract)

    @Test func enrichRunsVisionOnSuspectPagesOnly() {
        let formulaPage = formulaPdftotext + "\n" + String(repeating: "字", count: 200)
        let prosePage = prose + String(repeating: "字", count: 200)
        let config = TriageProbe.Config(textCharsMin: 200, fragmentRatioMax: 0.6)
        let base = TriageProbe.measure(pages: [prosePage, formulaPage], config: config)
        #expect(base.suspectPages == [2])

        var visionCalls: [Int] = []
        let enriched = TriageDivergence.enrich(
            report: base,
            pageTexts: [1: prosePage, 2: formulaPage],
            vision: { page in visionCalls.append(page); return formulaVision })

        // Vision ran for the suspect page ONLY — never for prose pages.
        #expect(visionCalls == [2])
        #expect(enriched.divergence != nil)
        #expect(enriched.divergence?.perPage.keys.sorted() == ["2"])
        // Everything else in the report is untouched.
        #expect(enriched.pages == base.pages)
        #expect(enriched.route == base.route)
    }

    @Test func enrichWithNoSuspectPagesCallsNothingAndReportsEmpty() {
        let prosePage = prose + String(repeating: "字", count: 200)
        let config = TriageProbe.Config(textCharsMin: 200, fragmentRatioMax: 0.6)
        let base = TriageProbe.measure(pages: [prosePage], config: config)
        #expect(base.suspectPages.isEmpty)

        var visionCalls = 0
        let enriched = TriageDivergence.enrich(report: base, pageTexts: [1: prosePage],
                                               vision: { _ in visionCalls += 1; return "" })
        #expect(visionCalls == 0)
        // Divergence WAS requested and ran over zero suspect pages: informants
        // present, per_page empty — "ran, nothing to report", not "did not run"
        // (P12: nil = no such concept, [:] = concept with nothing to report).
        #expect(enriched.divergence?.informants == ["pdftotext", "vision"])
        #expect(enriched.divergence?.perPage.isEmpty == true)
    }
}
