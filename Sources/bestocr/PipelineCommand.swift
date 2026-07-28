import ArgumentParser
import BestOCRKit
import Foundation

struct Pipeline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One command from input to deliverable: normalize → route → OCR → assemble → convert. Writes into its own output directory and refuses to overwrite an existing file unless told to.")

    @Argument(help: "One or more input files (pdf, png, jpg, jpeg, tiff, heic, bmp).")
    var inputs: [String]

    @Option(help: "Target format (v1: docx).")
    var to: String = "docx"

    @Option(help: "Output directory. Default: bestocr-out/ beside the first input — never the input's own directory, where your own files live.")
    var out: String?

    @Option(help: "Engine id or `auto` (default): recommend-ordered routing with a fallback chain.")
    var engine: String = "auto"

    @Option(help: "Render DPI for PDF inputs (evidence factor).")
    var dpi: Double = 150

    @Option(help: "Page spec for PDFs, e.g. \"1-3,7\" (default: all pages).")
    var pages: String = ""

    @Option(help: "Comma-separated language preference, e.g. \"zh-Hant,en\".")
    var lang: String = ""

    @Option(name: .customLong("doc-type"),
            help: "Workload label recorded in the condition tuple (e.g. math_pdf, scanned_doc, multicolumn_scan).")
    var docType: String = "unspecified"

    @Option(help: "auto mode: quality | speed | balanced routing priority.")
    var priority: String = "balanced"

    @Flag(help: "auto mode: require math-aware output (math_markdown engines only).")
    var math: Bool = false

    @Option(name: .customLong("document-class"),
            help: "auto mode: unspecified (default) | single-column | multi-column | tabular | mixed. The last three require a document-assembly engine.")
    var documentClass: String = "unspecified"

    @Option(help: "Force a converter: pandoc | macdoc. Default picks by content — math goes to pandoc (native OMath) when available, everything else to macdoc.")
    var converter: String?

    @Flag(help: "Replace existing outputs. Without this, a run that would overwrite anything refuses before doing any OCR.")
    var overwrite: Bool = false

    mutating func run() async throws {
        guard let prio = WorkloadSpec.Priority(rawValue: priority) else {
            throw ValidationError("--priority must be one of: quality, speed, balanced")
        }
        guard let docClass = DocumentClass.parse(documentClass) else {
            throw ValidationError("--document-class must be one of: "
                + DocumentClass.allCases.map(\.rawValue).joined(separator: ", "))
        }
        var forced: FileConverter.Kind?
        if let converter {
            guard let kind = FileConverter.Kind(rawValue: converter) else {
                throw ValidationError("--converter must be one of: "
                    + FileConverter.Kind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            forced = kind
        }
        guard let first = inputs.first else {
            throw ValidationError("give at least one input file")
        }
        let outDir = out.map { URL(fileURLWithPath: $0) }
            ?? OutputPlanner.defaultOutDir(for: URL(fileURLWithPath: first))
        let languages = lang.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        let report: PipelineReport
        do {
            report = try await PipelineFlow.run(
                inputs: inputs, to: to, outDir: outDir, engineID: engine, dpi: dpi,
                pageSpec: pages, languages: languages, docType: docType,
                priority: prio, needsMath: math, documentClass: docClass,
                converter: forced, overwrite: overwrite,
                registry: EngineRegistry.standard(),
                evidence: try EvidenceStore.load(from: EvidenceStore.defaultURL()),
                runLog: RunLog.default())
        } catch let error as OCREngineError {
            throw ValidationError(error.errorDescription ?? "\(error)")
        }

        print("output directory: \(report.outDir.path)")
        for item in report.items {
            print("")
            print("── \(URL(fileURLWithPath: item.input).lastPathComponent)")
            for notice in item.notices { print("   ℹ \(notice)") }
            for attempt in item.attempts where attempt.failure != nil {
                print("   ↷ \(attempt.engineID) skipped: \(attempt.failure!)")
            }
            if let engineID = item.engineID {
                print("   engine: \(engineID)")
            }
            if let blocks = item.blocks {
                print("   assembly: \(blocks) block(s) in reading order")
            }
            if let load = item.loadSeconds {
                print("   model load: \(String(format: "%.1f", load))s (excluded from per-page timing)")
            }
            if let markdown = item.markdown {
                print("   markdown: \(markdown.path)")
            }
            for hop in item.converterHops { print("   ↷ converter \(hop)") }
            if let failure = item.failure {
                print("   ✗ \(failure)")
                continue
            }
            if let target = item.target { print("   ✓ \(target.path)") }
            if let converter = item.converter { print("   converter: \(converter)") }
            if let runID = item.runID {
                print("   run id: \(runID)  (bestocr evidence ingest \(runID))")
            }
        }
        print("")
        print("\(report.succeeded.count) succeeded, \(report.failed.count) failed")
        // A partial batch must not report success to a script.
        if !report.failed.isEmpty { throw ExitCode.failure }
    }
}
