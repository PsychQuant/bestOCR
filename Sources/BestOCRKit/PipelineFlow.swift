import Foundation

/// What one input produced, stage by stage. Everything a caller needs to report
/// honestly — which engine ran, which hops were skipped, which converter did the
/// work — is a value here rather than something printed and lost.
public struct PipelineReport: Sendable {
    public struct Item: Sendable {
        public let input: String
        public let markdown: URL?
        public let target: URL?
        public let engineID: String?
        public let runID: String?
        public let attempts: [RunSummary.Attempt]
        public let notices: [String]
        public let blocks: Int?
        public let loadSeconds: Double?
        public let hasMath: Bool
        public let converter: String?
        /// Converters tried and failed before the one that worked — the same
        /// never-silent rule the engine fallback chain already follows.
        public let converterHops: [String]
        public let failure: String?
    }

    public let outDir: URL
    public let items: [Item]

    public var succeeded: [Item] { items.filter { $0.failure == nil } }
    public var failed: [Item] { items.filter { $0.failure != nil } }
}

/// One command from input to deliverable (#24): normalize → route → OCR →
/// assemble → convert. The stages already existed as separate subcommands; what
/// this adds is that the rules between them are enforced rather than described.
public enum PipelineFlow {
    /// v1 is docx-only, inherited from #1's scoping decision.
    public static let supportedFormats = ["docx"]

    public static func run(inputs: [String], to format: String, outDir: URL,
                           engineID: String = "auto", dpi: Double = 150,
                           pageSpec: String = "", languages: [String] = [],
                           docType: String = "unspecified",
                           priority: WorkloadSpec.Priority = .balanced,
                           needsMath: Bool = false,
                           documentClass: DocumentClass = .unspecified,
                           converter forced: FileConverter.Kind? = nil,
                           overwrite: Bool = false,
                           locateConverter: @Sendable (FileConverter.Kind) -> URL? = FileConverter.locate,
                           registry: EngineRegistry, evidence: EvidenceStore,
                           runLog: RunLog) async throws -> PipelineReport {
        // --- Pre-flight. Everything that can be known before spending minutes
        // --- of OCR is checked here, so a refusal is cheap.
        guard supportedFormats.contains(format) else {
            throw OCREngineError(engine: "pipeline",
                                 message: "unsupported target format '\(format)' — v1 supports: \(supportedFormats.joined(separator: ", "))")
        }
        guard !inputs.isEmpty else {
            throw OCREngineError(engine: "pipeline", message: "no input given")
        }
        let inputURLs = inputs.map { URL(fileURLWithPath: $0) }
        let missing = inputURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw OCREngineError(engine: "pipeline",
                                 message: "input not found: \(missing.map(\.path).joined(separator: ", "))")
        }
        let plans = OutputPlanner.plan(inputs: inputURLs, outDir: outDir,
                                      targetExtension: format)
        if !overwrite {
            let clashes = OutputPlanner.existingOutputs(plans)
            guard clashes.isEmpty else {
                throw OCREngineError(engine: "pipeline",
                                     message: "these outputs already exist and would be overwritten — pass --overwrite to replace them: "
                                         + clashes.map(\.lastPathComponent).joined(separator: ", "))
            }
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // --- Per input. One failure is recorded and the batch continues; the
        // --- caller gets a per-item verdict rather than an all-or-nothing one.
        var items: [PipelineReport.Item] = []
        for plan in plans {
            let stem = plan.markdown.deletingPathExtension().lastPathComponent
            do {
                let summary: RunSummary
                if engineID == "auto" {
                    summary = try await RunPipeline.executeAuto(
                        inputPath: plan.input.path, dpi: dpi, pageSpec: pageSpec,
                        languages: languages, docType: docType, priority: priority,
                        needsMath: needsMath, documentClass: documentClass,
                        outDir: outDir, outputStem: stem,
                        registry: registry, evidence: evidence, runLog: runLog)
                } else {
                    summary = try await RunPipeline.execute(
                        inputPath: plan.input.path, engineID: engineID, dpi: dpi,
                        pageSpec: pageSpec, languages: languages, docType: docType,
                        outDir: outDir, outputStem: stem,
                        registry: registry, runLog: runLog)
                }
                items.append(try convertStage(summary: summary, plan: plan, forced: forced,
                                              locate: locateConverter))
            } catch let error as OCREngineError {
                items.append(failure(plan: plan, message: error.errorDescription ?? error.message))
            } catch {
                items.append(failure(plan: plan, message: String(describing: error)))
            }
        }
        return PipelineReport(outDir: outDir, items: items)
    }

    static func convertStage(summary: RunSummary, plan: OutputPlan,
                            forced: FileConverter.Kind?,
                            locate: (FileConverter.Kind) -> URL?) throws -> PipelineReport.Item {
        let markdown = summary.outputMarkdown
        let text = (try? String(contentsOf: markdown, encoding: .utf8)) ?? ""
        let hasMath = MarkdownMath.containsMath(text)
        let pandocAvailable = locate(.pandoc) != nil
        let order = FileConverter.order(hasMath: hasMath, forced: forced,
                                       pandocAvailable: pandocAvailable)

        var hops: [String] = []
        for kind in order {
            if case .unavailable(let reason, let hint) = FileConverter.availability(kind, locate: locate) {
                hops.append("\(kind.rawValue): \(reason)" + (hint.map { " — install: \($0)" } ?? ""))
                continue
            }
            do {
                let outcome = try FileConverter.convert(kind, markdown: markdown,
                                                       target: plan.target, locate: locate)
                // Exit 0 is not proof a document exists.
                try DocxValidator.validate(plan.target)
                return item(summary: summary, plan: plan, hasMath: hasMath,
                            converter: outcome.attribution, hops: hops, failure: nil)
            } catch let error as OCREngineError {
                hops.append(error.errorDescription ?? error.message)
            }
        }
        // The markdown survived even though conversion did not, so the OCR work
        // is not thrown away — that is why the item still carries its path.
        return item(summary: summary, plan: plan, hasMath: hasMath, converter: nil,
                    hops: hops,
                    failure: "no converter produced a valid \(plan.target.pathExtension) — "
                        + hops.joined(separator: "; "))
    }

    static func item(summary: RunSummary, plan: OutputPlan, hasMath: Bool,
                    converter: String?, hops: [String],
                    failure: String?) -> PipelineReport.Item {
        PipelineReport.Item(
            input: plan.input.path, markdown: summary.outputMarkdown,
            target: failure == nil ? plan.target : nil,
            engineID: summary.result.engineID, runID: summary.runID,
            attempts: summary.attempts, notices: summary.notices,
            blocks: summary.result.document?.blocks.count,
            loadSeconds: summary.result.document?.loadSeconds,
            hasMath: hasMath, converter: converter, converterHops: hops,
            failure: failure)
    }

    static func failure(plan: OutputPlan, message: String) -> PipelineReport.Item {
        PipelineReport.Item(input: plan.input.path, markdown: nil, target: nil,
                            engineID: nil, runID: nil, attempts: [], notices: [],
                            blocks: nil, loadSeconds: nil, hasMath: false,
                            converter: nil, converterHops: [], failure: message)
    }
}
