import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import BestOCRKit

/// In-process PDF fixture: CoreText-drawn pages carry a real text layer that
/// pdftotext can extract, so run()'s file path (page counting, per-page
/// -layout invocation, subset rekeying) is covered without shipping binary
/// fixtures. pdftotext itself is probed per repo discipline — SKIP, never
/// fake-pass, when poppler is absent.
private func makePDF(pages: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("triage-fixture-\(UUID().uuidString).pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw OCREngineError(engine: "test", message: "cannot create PDF context")
    }
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    for text in pages {
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: mediaBox.insetBy(dx: 36, dy: 36), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

private let proseText = String(
    repeating: "The insurance policy provides comprehensive coverage for the holder. ",
    count: 20)

@Suite(.serialized)
struct TriageRunTests {

    private var pdftotextPresent: Bool { TriageProbe.locatePdftotext() != nil }
    private let config = TriageProbe.Config(textCharsMin: 200, fragmentRatioMax: 0.6)

    /// Regression: a page selection disjoint from the document (e.g.
    /// `--pages 50` on a 3-page PDF) must return an explicit degraded report,
    /// never trap on an empty range.
    @Test func disjointPageSelectionDegradesInsteadOfTrapping() throws {
        guard pdftotextPresent else { print("SKIP: pdftotext not installed"); return }
        let pdf = try makePDF(pages: [proseText, proseText, proseText])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let report = TriageProbe.run(inputPath: pdf.path, pages: [50], config: config)
        let degraded = try #require(report.degraded)
        #expect(degraded.reason.contains("no pages"))
        #expect(degraded.reason.contains("3"))
        #expect(report.route == .ocrFull)
    }

    @Test func emptyExplicitSelectionDegradesInsteadOfTrapping() throws {
        guard pdftotextPresent else { print("SKIP: pdftotext not installed"); return }
        let pdf = try makePDF(pages: [proseText])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let report = TriageProbe.run(inputPath: pdf.path, pages: [], config: config)
        #expect(report.degraded != nil)
    }

    /// Subset selection reports TRUE page numbers, not 1..N over the subset.
    @Test func subsetSelectionRekeysToTruePageNumbers() throws {
        guard pdftotextPresent else { print("SKIP: pdftotext not installed"); return }
        let pdf = try makePDF(pages: [proseText, proseText, proseText])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let report = TriageProbe.run(inputPath: pdf.path, pages: [2, 3], config: config)
        #expect(report.degraded == nil)
        #expect(report.pages.map(\.page) == [2, 3])
        #expect(Set(report.perPageRoutes.keys) == ["2", "3"])
    }

    /// Born-digital fixture end to end through the real pdftotext path.
    @Test func bornDigitalPDFRoutesTextDirect() throws {
        guard pdftotextPresent else { print("SKIP: pdftotext not installed"); return }
        let pdf = try makePDF(pages: [proseText, proseText])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let report = TriageProbe.run(inputPath: pdf.path, config: config)
        #expect(report.degraded == nil)
        #expect(report.route == .textDirect)
        #expect(report.pages.allSatisfy { $0.hasTextLayer })
    }

    // MARK: - runComplete divergence gate (no PDF or poppler needed)

    /// Without the divergence flag the report carries nil (= did not run) and
    /// no Vision/render work happens — image inputs cannot even reach the
    /// divergence branch, making this a type-level guarantee worth pinning.
    @Test func runCompleteWithoutFlagLeavesDivergenceNil() async throws {
        let report = try await TriageProbe.runComplete(
            inputPath: "/nonexistent/shot.png", divergence: false, config: config)
        #expect(report.divergence == nil)
    }

    /// With the flag on and zero suspect pages: informants with an empty map
    /// ("ran, nothing to score"), never nil — and no Vision pass.
    @Test func runCompleteFlagOnNoSuspectsReportsEmptyDivergence() async throws {
        let report = try await TriageProbe.runComplete(
            inputPath: "/nonexistent/shot.png", divergence: true, config: config)
        #expect(report.divergence?.informants == ["pdftotext", "vision"])
        #expect(report.divergence?.perPage.isEmpty == true)
    }
}
