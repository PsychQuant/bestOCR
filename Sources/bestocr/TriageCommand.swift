import ArgumentParser
import BestOCRKit
import CoreGraphics
import Foundation

struct Triage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measurement-based triage: does this input need OCR, and which pages "
            + "carry structure pdftotext shreds? Reports a route recommendation — never "
            + "executes it.")

    @Argument(help: "Input file (pdf, png, jpg, jpeg, tiff, heic, bmp).")
    var input: String

    @Option(help: "Page spec for PDFs, e.g. \"1-3,7\" (default: all pages).")
    var pages: String = ""

    @Flag(help: "Also measure pdftotext-vs-Vision divergence on suspect pages.")
    var divergence: Bool = false

    @Flag(help: "Print the full TriageReport as JSON instead of a human-readable summary.")
    var json: Bool = false

    mutating func run() async throws {
        // Page-spec parsing mirrors InputNormalizer.normalize's own use of
        // parsePages: open the PDF for its real page count first. Non-PDF
        // inputs (images) ignore --pages entirely — TriageProbe.run already
        // forces them to a single no-text-layer page.
        var pagesArray: [Int]? = nil
        if !pages.isEmpty,
           let doc = CGPDFDocument(URL(fileURLWithPath: input) as CFURL),
           doc.numberOfPages > 0 {
            pagesArray = InputNormalizer.parsePages(pages, count: doc.numberOfPages)
        }

        let report = try await TriageProbe.runComplete(
            inputPath: input, pages: pagesArray, divergence: divergence)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        print("route: \(report.route.rawValue)")
        for page in report.pages {
            let mark = page.suspect ? " ⚠ suspect" : ""
            print(String(format: "  page %d: text_chars=%d has_text_layer=%@ fragment_ratio=%.2f%@",
                         page.page, page.textChars,
                         page.hasTextLayer ? "true" : "false",
                         page.fragmentRatio, mark))
        }
        if !report.suspectPages.isEmpty {
            print("suspect_pages: \(report.suspectPages.map(String.init).joined(separator: ", "))")
        }
        if let divergence = report.divergence {
            print("divergence (informants: \(divergence.informants.joined(separator: ", "))):")
            let sorted = divergence.perPage.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            for (page, score) in sorted {
                print(String(format: "  page %@: %.3f", page, score))
            }
        }
        if let degraded = report.degraded {
            print("⚠ degraded: \(degraded.reason) — \(degraded.installHint)")
        }
        print("thresholds: text_chars_min=\(report.thresholds.textCharsMin) "
              + "fragment_ratio_max=\(String(format: "%.2f", report.thresholds.fragmentRatioMax))")
    }
}
