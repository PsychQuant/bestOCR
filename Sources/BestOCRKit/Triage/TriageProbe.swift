import Foundation
import CoreGraphics

/// Measurement-based triage (Tasks 1–2 of the flowchart): does this input
/// need OCR at all, and which pages carry structure that pdftotext shreds?
///
/// `measure(pages:config:)` is pure logic over extracted page texts — tests
/// cover it without poppler. `run(inputPath:...)` is the production entry:
/// it locates pdftotext (injectable), extracts per-page text, and degrades
/// EXPLICITLY when measurement cannot happen (missing tool, unreadable file).
/// Degraded route falls back to `ocr_full` — behaviour identical to the
/// pre-triage pipeline — and the report says so; triage never pretends.
public enum TriageProbe {

    public struct Config: Sendable {
        public let textCharsMin: Int
        public let fragmentRatioMax: Double

        public init(textCharsMin: Int = 200, fragmentRatioMax: Double = 0.6) {
            self.textCharsMin = textCharsMin
            self.fragmentRatioMax = fragmentRatioMax
        }

        /// Env overrides follow the repo convention (BESTOCR_*). Defaults are
        /// single-sample inductions, evidence-pending (see evidence/schema.md);
        /// garbage values fall back to defaults rather than crashing or
        /// silently adopting nonsense (0 or negative thresholds would turn
        /// triage into a constant function).
        public static func fromEnvironment(
            _ env: [String: String] = ProcessInfo.processInfo.environment
        ) -> Config {
            var textMin = 200
            if let raw = env["BESTOCR_TRIAGE_TEXT_MIN"], let v = Int(raw), v > 0 {
                textMin = v
            }
            var fragMax = 0.6
            if let raw = env["BESTOCR_TRIAGE_FRAG_MAX"], let v = Double(raw),
               v > 0, v <= 1 {
                fragMax = v
            }
            return Config(textCharsMin: textMin, fragmentRatioMax: fragMax)
        }
    }

    // MARK: - Pure measurement (Tasks 1 + 2)

    /// Classify already-extracted page texts. Page numbers are 1-based; the
    /// file-level route is `mixed` unless every page agrees (per-page verdicts
    /// are authoritative — this is what catches hybrid documents).
    public static func measure(pages pageTexts: [String], config: Config,
                               divergence: TriageReport.Divergence? = nil,
                               degraded: TriageReport.Degraded? = nil) -> TriageReport {
        var measures: [TriageReport.PageMeasure] = []
        var suspectPages: [Int] = []
        var routes: [String: String] = [:]

        for (index, text) in pageTexts.enumerated() {
            let page = index + 1
            let textChars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            let hasTextLayer = textChars >= config.textCharsMin
            let ratio = hasTextLayer ? fragmentRatio(of: text) : 0
            let suspect = hasTextLayer && ratio > config.fragmentRatioMax

            measures.append(.init(page: page, textChars: textChars,
                                  hasTextLayer: hasTextLayer,
                                  fragmentRatio: ratio, suspect: suspect))
            if suspect { suspectPages.append(page) }

            let route: TriageReport.Route =
                !hasTextLayer ? .ocrFull : (suspect ? .renderSuspectPages : .textDirect)
            routes["\(page)"] = route.rawValue
        }

        let distinct = Set(routes.values)
        let fileRoute: TriageReport.Route
        if let only = distinct.first, distinct.count == 1 {
            fileRoute = TriageReport.Route(rawValue: only) ?? .mixed
        } else if distinct.isEmpty {
            fileRoute = .ocrFull
        } else {
            fileRoute = .mixed
        }

        return TriageReport(pages: measures, suspectPages: suspectPages,
                            divergence: divergence, route: fileRoute,
                            perPageRoutes: routes,
                            thresholds: .init(textCharsMin: config.textCharsMin,
                                              fragmentRatioMax: config.fragmentRatioMax),
                            degraded: degraded)
    }

    /// Fragment ratio: share of 1–2 character tokens among all tokens on
    /// lines with more than 3 tokens. Shredded formulas leave exactly this
    /// signature (operators swallowed, symbols isolated); prose does not.
    /// Lines with ≤3 tokens (short labels, CJK prose that tokenizes as one
    /// run) are not evidence either way and are excluded.
    static func fragmentRatio(of text: String) -> Double {
        var short = 0, total = 0
        for line in text.components(separatedBy: .newlines) {
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count > 3 else { continue }
            total += tokens.count
            short += tokens.lazy.filter { $0.count <= 2 }.count
        }
        guard total > 0 else { return 0 }
        return Double(short) / Double(total)
    }

    // MARK: - Production entry (file → report)

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "bmp"]

    /// Locate pdftotext: BESTOCR_PDFTOTEXT override first, then PATH scan
    /// (same convention as FileConverter.locate).
    public static func locatePdftotext(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = env["BESTOCR_PDFTOTEXT"] {
            return FileManager.default.isExecutableFile(atPath: override)
                ? URL(fileURLWithPath: override) : nil
        }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/pdftotext"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    public static func run(inputPath: String,
                           pages requestedPages: [Int]? = nil,
                           config: Config = .fromEnvironment(),
                           locator: () -> URL? = { locatePdftotext() }) -> TriageReport {
        let ext = (inputPath as NSString).pathExtension.lowercased()

        // Images: no text layer by definition — no probe, no degradation.
        if imageExtensions.contains(ext) {
            return TriageReport(
                pages: [.init(page: 1, textChars: 0, hasTextLayer: false,
                              fragmentRatio: 0, suspect: false)],
                suspectPages: [], divergence: nil, route: .ocrFull,
                perPageRoutes: ["1": TriageReport.Route.ocrFull.rawValue],
                thresholds: .init(textCharsMin: config.textCharsMin,
                                  fragmentRatioMax: config.fragmentRatioMax),
                degraded: nil)
        }

        func degradedReport(_ reason: String, hint: String) -> TriageReport {
            TriageReport(pages: [], suspectPages: [], divergence: nil,
                         route: .ocrFull, perPageRoutes: [:],
                         thresholds: .init(textCharsMin: config.textCharsMin,
                                           fragmentRatioMax: config.fragmentRatioMax),
                         degraded: .init(reason: reason, installHint: hint))
        }

        guard let tool = locator() else {
            return degradedReport("pdftotext not found — text-layer measurement cannot run",
                                  hint: "brew install poppler")
        }

        let fileURL = URL(fileURLWithPath: inputPath)
        guard let document = CGPDFDocument(fileURL as CFURL), document.numberOfPages > 0 else {
            return degradedReport("cannot open PDF for page counting: \(inputPath)",
                                  hint: "verify the file exists and is a readable PDF")
        }

        let allPages = Array(1...document.numberOfPages)
        let requested = requestedPages.map(Set.init)
        let targetPages = requested.map { req in allPages.filter(req.contains) } ?? allPages
        // A disjoint or unparseable page selection must be an explicit error,
        // not a trap (mirrors InputNormalizer.normalize's guard) — an empty
        // selection would otherwise crash on Array(1...0) below.
        guard !targetPages.isEmpty else {
            return degradedReport(
                "page selection matches no pages (document has \(document.numberOfPages))",
                hint: "pass page numbers within 1...\(document.numberOfPages)")
        }

        var texts: [String] = []
        for page in targetPages {
            do {
                let result = try Subprocess.run(
                    tool,
                    arguments: ["-f", "\(page)", "-l", "\(page)", "-layout", inputPath, "-"],
                    timeout: 30)
                guard result.exitCode == 0 else {
                    return degradedReport(
                        "pdftotext failed on page \(page) (exit \(result.exitCode)): \(result.stderr.prefix(200))",
                        hint: "brew install poppler")
                }
                texts.append(result.stdout)
            } catch {
                return degradedReport("pdftotext failed on page \(page): \(error)",
                                      hint: "brew install poppler")
            }
        }

        var report = measure(pages: texts, config: config)
        // measure() numbers pages 1..N over the texts array; re-key to the
        // actual page numbers when a subset was requested.
        if targetPages != Array(1...texts.count) {
            report = rekey(report, to: targetPages)
        }
        return report
    }

    /// Re-map sequential page numbers (1..N over a filtered subset) back to
    /// the true page numbers of the source document.
    private static func rekey(_ report: TriageReport, to pages: [Int]) -> TriageReport {
        let mapped = report.pages.enumerated().map { index, m in
            TriageReport.PageMeasure(page: pages[index], textChars: m.textChars,
                                     hasTextLayer: m.hasTextLayer,
                                     fragmentRatio: m.fragmentRatio, suspect: m.suspect)
        }
        var routes: [String: String] = [:]
        for (index, page) in pages.enumerated() {
            if let r = report.perPageRoutes["\(index + 1)"] { routes["\(page)"] = r }
        }
        let suspects = report.suspectPages.map { pages[$0 - 1] }
        return TriageReport(pages: mapped, suspectPages: suspects,
                            divergence: report.divergence, route: report.route,
                            perPageRoutes: routes, thresholds: report.thresholds,
                            degraded: report.degraded)
    }
}
