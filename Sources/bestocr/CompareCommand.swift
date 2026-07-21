import ArgumentParser
import BestOCRKit
import Foundation

struct Compare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a local engine and a cloud reference on the same pages; report token recall (named formula, not ground truth).")

    @Argument(help: "Input file (pdf or image).")
    var input: String

    @Option(help: "Local engine id (see `bestocr list-engines`).")
    var engine: String

    @Option(help: "Cloud reference engine id (cloud.claude / cloud.openai / cloud.gemini).")
    var vs: String = "cloud.claude"

    @Option(help: "Output directory for per-side markdown.")
    var out: String = "."

    @Option(help: "Render DPI for PDF inputs.")
    var dpi: Double = 150

    @Option(help: "Page spec for PDFs, e.g. \"1-3\".")
    var pages: String = ""

    @Option(help: "Comma-separated language preference.")
    var lang: String = ""

    @Option(name: .customLong("doc-type"), help: "Workload label for condition tuples.")
    var docType: String = "unspecified"

    mutating func run() async throws {
        let registry = EngineRegistry.standard()
        guard let local = registry.engine(id: engine) else {
            throw ValidationError("unknown engine \(engine) — see bestocr list-engines")
        }
        guard let cloud = registry.engine(id: vs), cloud.family == .cloudReference else {
            throw ValidationError("--vs must be a cloud.* reference engine (got \(vs))")
        }
        for candidate in [local, cloud] {
            if case .unavailable(let reason, let hint) = await candidate.probe() {
                var message = "[\(candidate.id)] unavailable: \(reason)"
                if let hint { message += " — \(hint)" }
                throw ValidationError(message)
            }
        }

        // Normalize ONCE so both sides see identical page images.
        let normalized = try InputNormalizer.normalize(
            inputPath: input, dpi: dpi, pageSpec: pages, workDir: nil)
        defer { normalized.cleanup() }
        let languages = lang.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let request = OCRRequest(pages: normalized.pages, languages: languages,
                                 dpi: normalized.dpi, docType: docType)

        let localResult = try await local.recognize(request)
        let cloudResult = try await cloud.recognize(request)

        let outDir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent
        for result in [localResult, cloudResult] {
            let url = outDir.appendingPathComponent("\(stem).\(result.engineID).md")
            try result.text.write(to: url, atomically: true, encoding: .utf8)
        }

        let recall = Comparator.tokenRecall(candidate: localResult.text,
                                            reference: cloudResult.text)
        func total(_ result: OCRResult) -> String {
            String(format: "%.1f", result.pages.map(\.seconds).reduce(0, +))
        }
        print("COMPARE \(stem) (\(localResult.pages.count) page(s), doc-type: \(docType))")
        print("  \(local.id): \(total(localResult))s  |  \(cloud.id): \(total(cloudResult))s (\(cloudResult.condition.model))")
        print("  \(Comparator.formulaID) = \(String(format: "%.3f", recall))")
        print("  note: reference is a cloud model, not ground truth — not comparable to word_recall vs pdftotext")
        print("  outputs: \(outDir.path)/\(stem).<engine>.md")
    }
}
