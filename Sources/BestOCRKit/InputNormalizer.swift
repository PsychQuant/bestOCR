import Foundation
import PDFKit
import PDFToLaTeXCore

/// Normalized input: the page-image sequence every engine consumes (spec §5.2).
public struct NormalizedInput: Sendable {
    public let pages: [PageImage]
    public let dpi: Double?       // render DPI; nil for raw-image passthrough
    public let cleanupDir: URL?   // temp render dir to delete after use

    public func cleanup() {
        guard let cleanupDir else { return }
        try? FileManager.default.removeItem(at: cleanupDir)
    }
}

/// PDF → page images via PageRenderer; raw images pass through (spec §5.2).
public enum InputNormalizer {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "bmp"]

    /// Page-spec parser, ported from the instrument (measureOCR OCRLoop.swift)
    /// so `--pages 1-3,7` behaves identically across product and instrument.
    public static func parsePages(_ spec: String, count: Int) -> [Int] {
        let all = Array(1...max(count, 1))
        if spec.isEmpty { return all }
        var out: [Int] = []
        for part in spec.split(separator: ",") {
            if let dash = part.firstIndex(of: "-") {
                let rawA = Int(part[part.startIndex..<dash]) ?? 1
                let rawB = Int(part[part.index(after: dash)...]) ?? rawA
                let a = min(max(rawA, 1), count)
                let b = min(max(rawB, 1), count)
                out.append(contentsOf: a...max(a, b))
            } else if let n = Int(part) {
                out.append(n)
            }
        }
        return out.filter { $0 >= 1 && $0 <= count }
    }

    /// Contiguous (first, last) runs so the renderer is invoked once per run.
    static func contiguousRuns(_ pages: [Int]) -> [(first: Int, last: Int)] {
        let sorted = Array(Set(pages)).sorted()
        var runs: [(first: Int, last: Int)] = []
        for p in sorted {
            if let last = runs.last, p == last.last + 1 {
                runs[runs.count - 1].last = p
            } else {
                runs.append((first: p, last: p))
            }
        }
        return runs
    }

    public static func normalize(inputPath: String, dpi: Double, pageSpec: String,
                                 workDir: URL?) throws -> NormalizedInput {
        let url = URL(fileURLWithPath: inputPath)
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return NormalizedInput(pages: [PageImage(pageNumber: 1, url: url)],
                                   dpi: nil, cleanupDir: nil)
        }
        guard ext == "pdf" else {
            throw OCREngineError(engine: "normalizer",
                                 message: "unsupported input type .\(ext) — expected pdf or image (\(imageExtensions.sorted().joined(separator: "/")))")
        }
        guard let document = PDFDocument(url: url) else {
            throw OCREngineError(engine: "normalizer", message: "cannot open PDF: \(inputPath)")
        }
        let wanted = parsePages(pageSpec, count: document.pageCount)
        guard !wanted.isEmpty else {
            throw OCREngineError(engine: "normalizer",
                                 message: "page spec '\(pageSpec)' selects no pages (document has \(document.pageCount))")
        }
        let renderDir = workDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("bestocr-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
        let renderer = PageRenderer()
        var byPage: [Int: String] = [:]
        for run in contiguousRuns(wanted) {
            let rendered = try renderer.renderPages(
                pdfAt: url, outputDirectory: renderDir, dpi: dpi,
                firstPage: run.first, lastPage: run.last)
            for r in rendered { byPage[r.pageNumber] = r.imagePath }
        }
        let pages = wanted.compactMap { n in
            byPage[n].map { PageImage(pageNumber: n, url: URL(fileURLWithPath: $0)) }
        }
        return NormalizedInput(pages: pages, dpi: dpi, cleanupDir: renderDir)
    }
}
