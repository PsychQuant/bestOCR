import ArgumentParser
import BestOCRKit
import Foundation

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "OCR a PDF or image with an explicitly chosen engine.")

    @Argument(help: "Input file (pdf, png, jpg, jpeg, tiff, heic, bmp).")
    var input: String

    @Option(help: "Engine id — see `bestocr list-engines`.")
    var engine: String

    @Option(help: "Output directory for <stem>.md and <stem>.meta.json.")
    var out: String = "."

    @Option(help: "Render DPI for PDF inputs (evidence factor).")
    var dpi: Double = 150

    @Option(help: "Page spec for PDFs, e.g. \"1-3,7\" (default: all pages).")
    var pages: String = ""

    @Option(help: "Comma-separated language preference, e.g. \"zh-Hant,en\".")
    var lang: String = ""

    @Option(name: .customLong("doc-type"),
            help: "Workload label recorded in the condition tuple (e.g. math_pdf, scanned_book, screenshot).")
    var docType: String = "unspecified"

    @Option(help: "Override the VLM model tag (vlm.* engines only), e.g. glm-ocr-anova:q4_K_M.")
    var model: String?

    mutating func run() async throws {
        var registry = EngineRegistry.standard()
        if let model {
            guard engine.hasPrefix("vlm.") else {
                throw ValidationError("--model only applies to vlm.* engines (got \(engine))")
            }
            // Rebuild the chosen VLM engine with the override tag.
            let engines: [any OCREngine] = registry.engines.map { existing in
                guard existing.id == engine, let vlm = existing as? VLMEngine else { return existing }
                return VLMEngine(profile: vlm.profile, host: vlm.host, modelOverride: model)
            }
            registry = EngineRegistry(engines: engines)
        }
        let languages = lang.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        do {
            let summary = try await RunPipeline.execute(
                inputPath: input, engineID: engine, dpi: dpi, pageSpec: pages,
                languages: languages, docType: docType,
                outDir: URL(fileURLWithPath: out),
                registry: registry, runLog: RunLog.default())
            let pageCount = summary.result.pages.count
            let total = summary.result.pages.map(\.seconds).reduce(0, +)
            print("✓ \(engine): \(pageCount) page(s) in \(String(format: "%.1f", total))s")
            print("  markdown: \(summary.outputMarkdown.path)")
            print("  meta:     \(summary.outputMeta.path)")
            if summary.result.pages.contains(where: \.degenerateFlagged) {
                print("  ⚠ repetition guard tripped on at least one page — inspect the output")
            }
        } catch let error as OCREngineError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        }
    }
}
