import Foundation

extension TriageProbe {

    /// Full production entry shared by the CLI subcommand and the MCP tool:
    /// measurement (Tasks 1–2) plus, on request, divergence over suspect
    /// pages (Task 3: pdftotext vs Vision, suspect pages only).
    ///
    /// Divergence is opt-in and LOUD on failure: the caller explicitly asked
    /// for the measurement, so a Vision/render failure throws rather than
    /// silently returning a report without (or worse, with fabricated)
    /// divergence — an all-empty vision side would read as maximal divergence
    /// and steer the caller wrong.
    public static func runComplete(inputPath: String,
                                   pages: [Int]? = nil,
                                   divergence: Bool = false,
                                   config: Config = .fromEnvironment(),
                                   locator: () -> URL? = { locatePdftotext() }) async throws -> TriageReport {
        let report = run(inputPath: inputPath, pages: pages, config: config, locator: locator)
        guard divergence, report.degraded == nil else { return report }
        guard !report.suspectPages.isEmpty else {
            // Requested and ran over zero suspect pages: informants with an
            // empty map ("ran, nothing to score"), never nil ("did not run").
            return TriageDivergence.enrich(report: report, pageTexts: [:], vision: { _ in "" })
        }

        // pdftotext side: re-extract suspect pages (cheap — suspect sets are
        // small by construction; measurement texts are not retained by run()).
        guard let tool = locator() else { return report }
        var pageTexts: [Int: String] = [:]
        for page in report.suspectPages {
            let result = try Subprocess.run(
                tool, arguments: ["-f", "\(page)", "-l", "\(page)", "-layout", inputPath, "-"],
                timeout: 30)
            guard result.exitCode == 0 else {
                throw OCREngineError(engine: "triage",
                                     message: "pdftotext failed on page \(page) during divergence (exit \(result.exitCode))")
            }
            pageTexts[page] = result.stdout
        }

        // Vision side: render suspect pages only (spec cost contract), one
        // Vision pass over the rendered set.
        let pageSpec = report.suspectPages.map(String.init).joined(separator: ",")
        let normalized = try InputNormalizer.normalize(inputPath: inputPath, dpi: 200,
                                                       pageSpec: pageSpec, workDir: nil)
        defer { normalized.cleanup() }
        let vision = try await VisionEngine().recognize(
            OCRRequest(pages: normalized.pages, dpi: normalized.dpi, docType: "triage"))
        var visionTexts: [Int: String] = [:]
        for pageResult in vision.pages { visionTexts[pageResult.page] = pageResult.text }

        return TriageDivergence.enrich(report: report, pageTexts: pageTexts,
                                       vision: { visionTexts[$0] ?? "" })
    }
}
