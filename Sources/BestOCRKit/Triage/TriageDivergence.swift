import Foundation

/// Task 3 of the triage flowchart: divergence between EXTRACTION METHODS.
///
/// The consensus estimator's core insight — disagreement between informants is
/// itself the signal — reused for path selection: informants here are
/// extraction methods (`pdftotext` vs a visual reader), not OCR engines.
/// This is a thin entry over the existing text-level machinery
/// (`ItemExtractor` + `ConsensusAlignment`); `ConsensusPipeline` and the
/// estimator implementations are deliberately untouched (out of scope per the
/// change design — they stay engine-oriented).
///
/// Deliberately synchronous and engine-free: callers provide page text for
/// both informants. The production vision provider (render page → Vision
/// engine) lives at the surface layer, keeping this entry testable without
/// any engine or subprocess.
public enum TriageDivergence {

    public static let informants = ["pdftotext", "vision"]

    /// Measure per-page divergence between the two informants' texts.
    /// Score ∈ [0, 1]: share of aligned items on which the informants
    /// disagree (normalized text inequality, or presence on one side only).
    public static func measure(pages: [Int],
                               pdftotext: (Int) -> String,
                               vision: (Int) -> String) -> TriageReport.Divergence {
        var perPage: [String: Double] = [:]
        for page in pages {
            let a = ItemExtractor.extract(page: page, text: pdftotext(page))
            let b = ItemExtractor.extract(page: page, text: vision(page))
            perPage["\(page)"] = divergence(a, b, page: page)
        }
        return .init(informants: informants, perPage: perPage)
    }

    /// Enrich a measured report with divergence over its suspect pages ONLY —
    /// the cost contract of "cheap triage" (two extractions, suspect pages
    /// only). Pages, routes, and thresholds pass through untouched. When there
    /// are no suspect pages the result carries informants with an empty map:
    /// divergence RAN and found nothing to score ([:]), which is distinct
    /// from divergence never requested (nil).
    public static func enrich(report: TriageReport,
                              pageTexts: [Int: String],
                              vision: (Int) -> String) -> TriageReport {
        let divergence = measure(pages: report.suspectPages,
                                 pdftotext: { pageTexts[$0] ?? "" },
                                 vision: vision)
        return TriageReport(pages: report.pages, suspectPages: report.suspectPages,
                            divergence: divergence, route: report.route,
                            perPageRoutes: report.perPageRoutes,
                            thresholds: report.thresholds, degraded: report.degraded)
    }

    static func divergence(_ a: [ExtractedItem], _ b: [ExtractedItem], page: Int) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        if a.isEmpty || b.isEmpty { return 1 }
        let aligned = ConsensusAlignment.align(
            page: page, extractions: [informants[0]: a, informants[1]: b])
        guard !aligned.isEmpty else { return 0 }
        let disagreements = aligned.filter { item in
            guard let first = item.responses[informants[0]],
                  let second = item.responses[informants[1]] else { return true }
            return first.normalized != second.normalized
        }.count
        return Double(disagreements) / Double(aligned.count)
    }
}
