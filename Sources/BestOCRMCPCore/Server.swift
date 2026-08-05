import BestOCRKit
import CoreGraphics
import Foundation
import MCP

/// bestOCR's MCP surface (spec §7 Flow A; bestASR #80 pattern): a long-lived
/// stdio server linking BestOCRKit directly. VLM warmth lives in the Ollama
/// server (keep_alive); this process contributes persistent probes plus the
/// single-flight gate that stops concurrent heavy OCR from overloading the
/// local model server or the Python tools. stdout carries JSON-RPC
/// exclusively; every human-facing diagnostic goes to stderr.
public actor BestOCRMCPServer {
    let registry: EngineRegistry
    let runLog: RunLog
    let evidenceURL: URL
    let server: Server
    /// Serializes heavy OCR; read-only tools bypass it.
    let ocrGate = SingleFlight()
    let jobs = JobRegistry()

    /// `ocr_result` server-side wait — below typical MCP client timeouts so
    /// the poll call cannot itself become the unbounded block it avoids.
    static let resultWaitCap: Duration = .seconds(25)

    public init(registry: EngineRegistry = .standard(),
                runLog: RunLog = .default(),
                evidenceURL: URL = EvidenceStore.defaultURL()) {
        self.registry = registry
        self.runLog = runLog
        self.evidenceURL = evidenceURL
        self.server = Server(
            name: "bestocr-mcp",
            version: BestOCRVersion.semver,
            capabilities: .init(tools: .init())
        )
    }

    public func run() async throws {
        await registerHandlers()
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    // MARK: - Tools (internal so tests enumerate + cross-check dispatch)

    static func defineTools() -> [Tool] {
        [
            Tool(
                name: "ocr",
                description: "OCR a PDF or image. Default engine is auto — recommend-ordered "
                    + "routing with a fallback chain past unavailable/failing engines; pass "
                    + "engine to pin one (no fallback). Writes <stem>.md + <stem>.meta.json "
                    + "and logs the evidence condition tuple. Long documents: pass "
                    + "async=true, then poll ocr_status / ocr_result.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "input_path": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to the PDF or image"),
                        ]),
                        "engine": .object([
                            "type": .string("string"),
                            "description": .string("Engine id from list_engines (e.g. vision, vlm.glm-ocr) or \"auto\" (default: recommend-ordered routing + fallback)"),
                        ]),
                        "priority": .object([
                            "type": .string("string"),
                            "description": .string("auto mode: quality | speed | balanced (default balanced)"),
                        ]),
                        "math": .object([
                            "type": .string("boolean"),
                            "description": .string("auto mode: require math-aware output"),
                        ]),
                        "out_dir": .object([
                            "type": .string("string"),
                            "description": .string("Output directory (default: a temp dir; paths returned either way)"),
                        ]),
                        "dpi": .object([
                            "type": .string("number"),
                            "description": .string("Render DPI for PDF inputs (default 150; evidence factor)"),
                        ]),
                        "pages": .object([
                            "type": .string("string"),
                            "description": .string("Page spec for PDFs, e.g. \"1-3,7\" (default: all)"),
                        ]),
                        "lang": .object([
                            "type": .string("string"),
                            "description": .string("Comma-separated language preference, e.g. \"zh-Hant,en\""),
                        ]),
                        "doc_type": .object([
                            "type": .string("string"),
                            "description": .string("Workload label for the condition tuple (math_pdf / scanned_doc / screenshot / …)"),
                        ]),
                        "document_class": .object([
                            "type": .string("string"),
                            "description": .string("Structural class: unspecified (default) | single_column | multi_column | tabular | mixed. The last three restrict candidates to document-assembly engines (doc.*), which resolve reading order but are substantially slower than per-page transcription"),
                        ]),
                        "model": .object([
                            "type": .string("string"),
                            "description": .string("VLM model-tag override (vlm.* engines only), e.g. glm-ocr-anova:q4_K_M"),
                        ]),
                        "async": .object([
                            "type": .string("boolean"),
                            "description": .string("Return a job_id immediately; poll ocr_status / ocr_result"),
                        ]),
                    ]),
                    "required": .array([.string("input_path")]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "pipeline",
                description: "One call from input to deliverable: normalize → route → OCR "
                    + "→ assemble → convert. Writes into its own output directory and "
                    + "REFUSES before doing any OCR if an output already exists (pass "
                    + "overwrite). The converter is chosen by content — math-bearing "
                    + "markdown goes to pandoc for native Word OMath equations, otherwise "
                    + "macdoc with literal LaTeX — and the choice is reported so a "
                    + "fidelity problem can be attributed correctly. The produced file is "
                    + "structurally validated, not assumed from an exit code. Long "
                    + "documents: pass async=true, then poll ocr_status / ocr_result.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "input_path": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to a PDF or image (use input_paths for a batch)"),
                        ]),
                        "input_paths": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Absolute paths for a batch. Colliding stems from different folders are suffixed so they cannot overwrite each other"),
                        ]),
                        "to": .object([
                            "type": .string("string"),
                            "description": .string("Target format (v1: docx)"),
                        ]),
                        "out_dir": .object([
                            "type": .string("string"),
                            "description": .string("Output directory. Default: bestocr-out/ beside the first input — never the input's own folder, where the user's own files live"),
                        ]),
                        "engine": .object([
                            "type": .string("string"),
                            "description": .string("Engine id or \"auto\" (default: recommend-ordered routing + fallback)"),
                        ]),
                        "doc_type": .object([
                            "type": .string("string"),
                            "description": .string("Workload label for the condition tuple (math_pdf / scanned_doc / multicolumn_scan / …)"),
                        ]),
                        "document_class": .object([
                            "type": .string("string"),
                            "description": .string("unspecified (default) | single_column | multi_column | tabular | mixed. The last three restrict candidates to document-assembly engines"),
                        ]),
                        "priority": .object([
                            "type": .string("string"),
                            "description": .string("quality | speed | balanced (default balanced)"),
                        ]),
                        "math": .object([
                            "type": .string("boolean"),
                            "description": .string("auto mode: require math-aware output"),
                        ]),
                        "dpi": .object([
                            "type": .string("number"),
                            "description": .string("Render DPI for PDF inputs (default 150)"),
                        ]),
                        "pages": .object([
                            "type": .string("string"),
                            "description": .string("Page spec for PDFs, e.g. \"1-3,7\" (default: all)"),
                        ]),
                        "lang": .object([
                            "type": .string("string"),
                            "description": .string("Comma-separated language preference, e.g. \"zh-Hant,en\""),
                        ]),
                        "converter": .object([
                            "type": .string("string"),
                            "description": .string("Force pandoc or macdoc. Forcing disables fallback, because reporting a converter that did not run would be untrue"),
                        ]),
                        "overwrite": .object([
                            "type": .string("boolean"),
                            "description": .string("Replace existing outputs. Without it, a run that would overwrite anything refuses before any OCR"),
                        ]),
                        "async": .object([
                            "type": .string("boolean"),
                            "description": .string("Return a job_id immediately; poll ocr_status / ocr_result"),
                        ]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "recommend",
                description: "Evidence-labelled engine recommendation for a workload: a "
                    + "tier-named ranking citing measured rows when evidence exists, otherwise "
                    + "an honest evidence-pending capability filter (never a guess).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "doc_type": .object([
                            "type": .string("string"),
                            "description": .string("Workload doc type matching evidence rows (math_pdf / scanned_doc / screenshot / …)"),
                        ]),
                        "lang": .object([
                            "type": .string("string"),
                            "description": .string("Comma-separated required languages, e.g. \"zh-Hant,en\""),
                        ]),
                        "priority": .object([
                            "type": .string("string"),
                            "description": .string("quality | speed | balanced (default balanced)"),
                        ]),
                        "math": .object([
                            "type": .string("boolean"),
                            "description": .string("Require math-aware output (math_markdown engines only)"),
                        ]),
                        "document_class": .object([
                            "type": .string("string"),
                            "description": .string("Structural class: unspecified (default) | single_column | multi_column | tabular | mixed. The last three restrict candidates to document-assembly engines (doc.*), which resolve reading order but are substantially slower than per-page transcription"),
                        ]),
                    ]),
                    "required": .array([.string("doc_type")]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "consensus",
                description: "Multi-engine consensus OCR: run several engines over the same "
                    + "input, align items (line-primary, table cells split), adjudicate with "
                    + "a selectable estimator (see `adjudicator`; Dawid-Skene-lite by "
                    + "default). Writes <stem>.consensus.md (⚠ marks "
                    + "low-consensus items) + <stem>.consensus.json (per-engine competence, "
                    + "low-consensus review list). Long documents: pass async=true, then "
                    + "poll ocr_status / ocr_result.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "input_path": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to the PDF or image"),
                        ]),
                        "engines": .object([
                            "type": .string("string"),
                            "description": .string("Comma-separated engine ids (default: every available local engine; needs ≥2)"),
                        ]),
                        "adjudicator": .object([
                            "type": .string("string"),
                            "description": .string("ds-lite (default) | majority (control, no competence) | ds-full (directional character confusion; for systematic 0/O-type errors) | prior-weighted (competence from measured word_recall rows). These estimate DIFFERENT things — their outputs are distinct estimands and must never be cross-ranked."),
                        ]),
                        "out_dir": .object([
                            "type": .string("string"),
                            "description": .string("Output directory (default: a temp dir; paths returned either way)"),
                        ]),
                        "dpi": .object([
                            "type": .string("number"),
                            "description": .string("Render DPI for PDF inputs (default 150)"),
                        ]),
                        "pages": .object([
                            "type": .string("string"),
                            "description": .string("Page spec for PDFs, e.g. \"1-3,7\" (default: all)"),
                        ]),
                        "lang": .object([
                            "type": .string("string"),
                            "description": .string("Comma-separated language preference, e.g. \"zh-Hant,en\""),
                        ]),
                        "doc_type": .object([
                            "type": .string("string"),
                            "description": .string("Workload label (e.g. math_pdf, scanned_doc, gov_doc)"),
                        ]),
                        "async": .object([
                            "type": .string("boolean"),
                            "description": .string("Run as a background job (poll ocr_status / ocr_result)"),
                        ]),
                    ]),
                    "required": .array([.string("input_path")]),
                ]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "triage",
                description: "Measurement-based triage — probes each page's text layer / "
                    + "structure (no OCR performed) and returns a recommended route: "
                    + "text_direct / render_suspect_pages / ocr_full / mixed, plus suspect "
                    + "page numbers. Pass divergence=true to additionally measure pdftotext "
                    + "vs Vision divergence on suspect pages only. When poppler (pdftotext) "
                    + "is unavailable, returns a degraded report (reason + install hint) "
                    + "with route ocr_full — identical to pre-triage behavior.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "input_path": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to the PDF or image"),
                        ]),
                        "pages": .object([
                            "type": .string("string"),
                            "description": .string("Page spec for PDFs, e.g. \"1-3,7\" (default: all)"),
                        ]),
                        "divergence": .object([
                            "type": .string("boolean"),
                            "description": .string("Measure pdftotext vs Vision divergence on suspect pages (default false)"),
                        ]),
                    ]),
                    "required": .array([.string("input_path")]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "list_engines",
                description: "Probe every registered engine (Vision, tesseract, Python-tool "
                    + "adapters, Ollama VLMs) and show availability + install hints.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "list_models",
                description: "List the admitted VLM model profiles (default tags, prompt "
                    + "contracts, output levels) — see evidence/candidates.json for tiers.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ocr_status",
                description: "Check an async ocr job (started via ocr with async=true). "
                    + "Returns running | done | failed | unknown. Cheap, non-blocking.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object([
                            "type": .string("string"),
                            "description": .string("Job id returned by an async ocr call"),
                        ])
                    ]),
                    "required": .array([.string("job_id")]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "ocr_result",
                description: "Fetch an async ocr job's result. Long-polls server-side until "
                    + "the job finishes or a cap elapses, then returns the result, a "
                    + "still_running marker (call again), or the typed error.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object([
                            "type": .string("string"),
                            "description": .string("Job id returned by an async ocr call"),
                        ])
                    ]),
                    "required": .array([.string("job_id")]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
        ]
    }

    func registerHandlers() async {
        let tools = Self.defineTools()
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return CallTool.Result(content: [.text("server unavailable")], isError: true)
            }
            return await self.execute(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    /// Dispatch — every failure becomes a loud tool error; the server loop
    /// never dies on a bad call.
    func execute(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let text = try await dispatch(name: name, arguments: arguments)
            return CallTool.Result(content: [.text(text)], isError: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            return CallTool.Result(content: [.text(message)], isError: true)
        }
    }

    func dispatch(name: String, arguments args: [String: Value]) async throws -> String {
        switch name {
        case "ocr":
            return try await handleOCR(args)
        case "pipeline":
            return try await handlePipeline(args)
        case "consensus":
            return try await handleConsensus(args)
        case "triage":
            return try await handleTriage(args)
        case "recommend":
            return try handleRecommend(args)
        case "list_engines":
            return await handleListEngines()
        case "list_models":
            return Self.renderModels()
        case "ocr_status":
            let id = try requiredString("job_id", in: args)
            switch await jobs.status(id) {
            case .running: return "running"
            case .done: return "done"
            case .failed(let message): return "failed: \(message)"
            case nil: return "unknown job (never existed, or evicted after retention)"
            }
        case "ocr_result":
            let id = try requiredString("job_id", in: args)
            switch await jobs.awaitResult(id, cap: Self.resultWaitCap) {
            case .result(let text): return text
            case .stillRunning: return "still_running — call ocr_result again"
            case .failed(let message):
                throw OCREngineError(engine: "mcp", message: message)
            case .unknown:
                throw OCREngineError(engine: "mcp",
                                     message: "unknown job (never existed, or evicted after retention)")
            }
        default:
            throw OCREngineError(engine: "mcp", message: "unknown tool: \(name)")
        }
    }

    // MARK: - Handlers


    private func handlePipeline(_ args: [String: Value]) async throws -> String {
        // Parsed outside the gate: a bad argument must fail immediately, not
        // after queueing behind someone else's OCR.
        var inputs: [String] = []
        if let single = args["input_path"]?.stringValue, !single.isEmpty {
            inputs.append(single)
        }
        if case .array(let items)? = args["input_paths"] {
            inputs.append(contentsOf: items.compactMap(\.stringValue))
        }
        guard !inputs.isEmpty else {
            throw OCREngineError(engine: "mcp",
                                 message: "missing required argument: input_path (or input_paths)")
        }
        let format = args["to"]?.stringValue ?? "docx"
        let outDir = args["out_dir"]?.stringValue
            ?? OutputPlanner.defaultOutDir(for: URL(fileURLWithPath: inputs[0])).path
        let engineID = args["engine"]?.stringValue ?? "auto"
        let priorityRaw = args["priority"]?.stringValue ?? "balanced"
        guard let priority = WorkloadSpec.Priority(rawValue: priorityRaw) else {
            throw OCREngineError(engine: "mcp",
                                 message: "priority must be one of: quality, speed, balanced")
        }
        let documentClassRaw = args["document_class"]?.stringValue ?? "unspecified"
        guard let documentClass = DocumentClass.parse(documentClassRaw) else {
            throw OCREngineError(engine: "mcp",
                                 message: "document_class must be one of: "
                                     + DocumentClass.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let forced: FileConverter.Kind? = try args["converter"]?.stringValue.map { raw in
            guard let kind = FileConverter.Kind(rawValue: raw) else {
                throw OCREngineError(engine: "mcp",
                                     message: "converter must be one of: "
                                         + FileConverter.Kind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return kind
        }
        let languages = (args["lang"]?.stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let dpi = args["dpi"]?.doubleValue ?? 150
        let pageSpec = args["pages"]?.stringValue ?? ""
        let docType = args["doc_type"]?.stringValue ?? "unspecified"
        let needsMath = args["math"]?.boolValue ?? false
        let overwrite = args["overwrite"]?.boolValue ?? false

        let gate = ocrGate
        let runLog = self.runLog
        let evidenceURL = self.evidenceURL
        let registrySnapshot = registry
        let capturedInputs = inputs
        let work: @Sendable () async throws -> String = {
            try await gate.run {
                let report = try await PipelineFlow.run(
                    inputs: capturedInputs, to: format,
                    outDir: URL(fileURLWithPath: outDir), engineID: engineID,
                    dpi: dpi, pageSpec: pageSpec, languages: languages,
                    docType: docType, priority: priority, needsMath: needsMath,
                    documentClass: documentClass, converter: forced,
                    overwrite: overwrite, registry: registrySnapshot,
                    evidence: try EvidenceStore.load(from: evidenceURL),
                    runLog: runLog)
                let text = Self.renderPipelineReport(report, registry: registrySnapshot)
                // A partial batch must not read as success. Throwing carries the
                // WHOLE report as the error text, so nothing is lost by failing.
                guard report.failed.isEmpty else {
                    throw OCREngineError(engine: "pipeline", message: text)
                }
                return text
            }
        }
        if args["async"]?.boolValue == true {
            let id = await jobs.start {
                do { return try await work() } catch let error as OCREngineError {
                    throw JobError(error.errorDescription ?? error.message)
                }
            }
            return "job started\njob_id: \(id)\npoll with ocr_status / ocr_result"
        }
        return try await work()
    }

    static func renderPipelineReport(_ report: PipelineReport,
                                     registry: EngineRegistry) -> String {
        var lines = ["output directory: \(report.outDir.path)"]
        for item in report.items {
            lines.append("")
            lines.append("── \(URL(fileURLWithPath: item.input).lastPathComponent)")
            lines.append(contentsOf: item.notices.map { "   ℹ \($0)" })
            for attempt in item.attempts where attempt.failure != nil {
                lines.append("   ↷ \(attempt.engineID) skipped: \(attempt.failure!)")
            }
            if let engineID = item.engineID {
                lines.append("   engine: \(engineID)")
                if let tradeoff = registry.engine(id: engineID)?.tradeoffNote {
                    lines.append("   tradeoff: \(tradeoff)")
                }
            }
            if let blocks = item.blocks {
                lines.append("   assembly: \(blocks) block(s) in reading order")
            }
            if let load = item.loadSeconds {
                lines.append("   model load: \(String(format: "%.1f", load))s (excluded from per-page timing)")
            }
            if let markdown = item.markdown { lines.append("   markdown: \(markdown.path)") }
            lines.append(contentsOf: item.converterHops.map { "   ↷ converter \($0)" })
            if let failure = item.failure {
                lines.append("   ✗ \(failure)")
                continue
            }
            if let target = item.target { lines.append("   ✓ \(target.path)") }
            if let converter = item.converter { lines.append("   converter: \(converter)") }
            if let runID = item.runID {
                lines.append("   run id: \(runID)  (bestocr evidence ingest \(runID))")
            }
        }
        lines.append("")
        lines.append("\(report.succeeded.count) succeeded, \(report.failed.count) failed")
        return lines.joined(separator: "\n")
    }

    private func handleConsensus(_ args: [String: Value]) async throws -> String {
        // Parse outside the gate (same discipline as handleOCR).
        let inputPath = try requiredString("input_path", in: args)
        let outDir = args["out_dir"]?.stringValue
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("bestocr-consensus-\(UUID().uuidString)").path
        let dpi = args["dpi"]?.doubleValue ?? 150
        let pageSpec = args["pages"]?.stringValue ?? ""
        let docType = args["doc_type"]?.stringValue ?? "unspecified"
        let languages = (args["lang"]?.stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let engineIDs = (args["engines"]?.stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Unknown ids fail loud inside the pipeline rather than defaulting —
        // a silent fallback would label another model's output with the
        // requested one's estimand name (#17).
        let adjudicatorID = args["adjudicator"]?.stringValue ?? "ds-lite"
        let gate = ocrGate
        let registrySnapshot = registry
        let runLogSnapshot = runLog
        let work: @Sendable () async throws -> String = {
            try await gate.run {
                var ids = engineIDs
                if ids.isEmpty {
                    for (engine, availability) in await registrySnapshot.probeAll() {
                        if case .available = availability, engine.family != .cloudReference {
                            ids.append(engine.id)
                        }
                    }
                }
                let summary = try await ConsensusPipeline.execute(
                    inputPath: inputPath, engineIDs: ids, dpi: dpi, pageSpec: pageSpec,
                    languages: languages, docType: docType,
                    outDir: URL(fileURLWithPath: outDir), registry: registrySnapshot,
                    runLog: runLogSnapshot, adjudicatorID: adjudicatorID)
                return Self.renderConsensusSummary(summary)
            }
        }
        if args["async"]?.boolValue == true {
            let id = await jobs.start {
                do { return try await work() } catch let error as OCREngineError {
                    throw JobError(error.errorDescription ?? error.message)
                }
            }
            return "job started\njob_id: \(id)\npoll with ocr_status / ocr_result"
        }
        return try await work()
    }

    static func renderConsensusSummary(_ summary: ConsensusRunSummary) -> String {
        var lines: [String] = []
        lines.append("engines: \(summary.engines.joined(separator: ", "))")
        for (id, reason) in summary.skipped.sorted(by: { $0.key < $1.key }) {
            // "One line, one fact" — id AND reason are outside-influenced
            // (reason really carries multi-line adapter stderr; R2 NEW-1/2).
            lines.append("skipped: \(ConsensusPipeline.oneLine(id)) — "
                         + ConsensusPipeline.oneLine(reason))
        }
        // #38: a refusal is a measurement outcome — say it first and plainly.
        if summary.refused {
            lines.append("REFUSED: \(summary.refusalReason ?? "co-answer share below threshold")")
            lines.append("No competence was estimated — the report carries the alignment")
            lines.append("diagnostics (response-count distribution, agreement matrix).")
            // R1 F-10: on refusal the reader most needs to know which engines
            // the check ran WITHOUT — that lived only in the JSON.
            if let check = summary.singleConsensus, !check.excludedEngines.isEmpty {
                lines.append("excluded: \(check.excludedEngines.joined(separator: ", "))"
                             + " — no co-answer data (not part of the refused check)")
            }
            // #13 F15c is END-TO-END: a refusal that replaced a previous
            // valid run's artifacts must say so here, not only in the
            // summary struct (R2 — four independent reviewers converged).
            if summary.overwrote {
                lines.append("note: overwrote existing consensus artifacts for this stem/out-dir")
            }
            lines.append("transcript: \(ConsensusPipeline.oneLine(summary.outputMarkdown.path))")
            lines.append("report: \(ConsensusPipeline.oneLine(summary.outputReport.path))")
            return lines.joined(separator: "\n")
        }
        let est = summary.estimate
        lines.append("adjudicator: \(est.adjudicator)")
        // #39: the single-consensus check — competence below is only
        // meaningful if this held. untestable ≠ passed; both are disclosed.
        // No line at all is RESERVED for "no competence claimed" (majority);
        // an unchecked competence claim (rover) must say it is unchecked.
        if let check = summary.singleConsensus {
            var line: String
            switch check.verdict {
            case "passed":
                // Clamped rank-1 ratio is a clamp artifact, not a measurement
                // — read the RECORDED flag, never infer from magnitude
                // (R1 F-07 → R2 codex 4). The threshold appears on the
                // passed line because it is env-overridable and matters most
                // exactly when it was changed (R2 DA-1).
                let ratioText = check.ratioUnbounded == true
                    ? "unbounded (λ2 ≈ 0 — rank-1 agreement)"
                    : check.ratio.map { String(format: "%.2f", $0) } ?? "n/a"
                let thresholdText = check.minRatio.map {
                    String(format: " (threshold %.2f)", $0)
                } ?? ""
                line = "single-consensus: passed — eigenvalue ratio "
                    + ratioText + thresholdText
            default:
                line = "single-consensus: \(check.verdict) — \(check.reason ?? "unspecified")"
            }
            if !check.excludedEngines.isEmpty {
                line += " (excluded: \(check.excludedEngines.joined(separator: ", "))"
                    + " — no co-answer data)"
            }
            lines.append(line)
        } else if AdjudicatorRegistry.isSequenceAdjudicator(est.adjudicator),
                  est.diagnostics.overallCompetence != nil {
            // R1 B2: rover reports competence but its confusion-network
            // alignment sits outside this check (#49) — the ranking below
            // carries an UNTESTED single-key assumption, and silence here
            // would read as "nothing claimed". Guard is the EXPLICIT
            // sequence-adjudicator predicate, not a competence-nil proxy —
            // the proxy was the very criterion #39 renamed away (R2 DA-2).
            lines.append("single-consensus: not checked — \(est.adjudicator) reports "
                         + "competence but its alignment model is outside this check "
                         + "(#49); the single-key assumption is untested")
        }
        let rounds = est.diagnostics.iterations.map { " — \($0) iterations" } ?? ""
        // solo = single-engine items the aligner never grouped — NOT disputes (#38).
        let solo = est.items.filter { item in
            item.responses.values.filter { !$0.isEmpty }.count <= 1
        }.count
        lines.append("items: \(est.items.count) (\(est.items.filter(\.lowConsensus).count) low-consensus, "
                     + "of which \(solo) solo/unaligned — single response, not a dispute)\(rounds)")
        // nil = this adjudicator has no competence notion; say so rather than
        // printing an empty list that reads like "everyone scored nothing" (#17).
        if let competence = est.diagnostics.overallCompetence {
            let ns = est.diagnostics.informativeItems
            for (id, c) in competence.sorted(by: { $0.value > $1.value }) {
                // n makes a bare prior visibly different from a measurement (#38).
                let suffix = ns.map { counts -> String in
                    let n = counts[id] ?? 0
                    return n == 0 ? " (prior — no informative items)" : " (n=\(n))"
                } ?? ""
                lines.append(String(format: "competence: %@ %.3f%@", id, c, suffix))
            }
        } else {
            lines.append("competence: n/a — \(est.adjudicator) has no competence model")
        }
        lines.append("transcript: \(ConsensusPipeline.oneLine(summary.outputMarkdown.path))")
        lines.append("report: \(ConsensusPipeline.oneLine(summary.outputReport.path))")
        lines.append("run-id: \(summary.runID) (promote with the evidence ingest gate)")
        if summary.overwrote {
            lines.append("note: overwrote existing consensus artifacts for this stem/out-dir")
        }
        return lines.joined(separator: "\n")
    }

    private func handleOCR(_ args: [String: Value]) async throws -> String {
        // Parse outside the gate: malformed calls fail fast and in parallel —
        // only real OCR work queues (bestASR F1/F2 lesson).
        let inputPath = try requiredString("input_path", in: args)
        let engineID = args["engine"]?.stringValue ?? "auto"
        let outDir = args["out_dir"]?.stringValue
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("bestocr-mcp-\(UUID().uuidString)").path
        let dpi = args["dpi"]?.doubleValue ?? 150
        let pageSpec = args["pages"]?.stringValue ?? ""
        let docType = args["doc_type"]?.stringValue ?? "unspecified"
        let languages = (args["lang"]?.stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var effectiveRegistry = registry
        if let modelOverride = args["model"]?.stringValue {
            guard engineID.hasPrefix("vlm.") else {
                throw OCREngineError(engine: "mcp",
                                     message: "model override only applies to vlm.* engines (got \(engineID))")
            }
            let engines: [any OCREngine] = registry.engines.map { existing in
                guard existing.id == engineID, let vlm = existing as? VLMEngine else { return existing }
                return VLMEngine(profile: vlm.profile, host: vlm.host, modelOverride: modelOverride)
            }
            effectiveRegistry = EngineRegistry(engines: engines)
        }
        let priorityRaw = args["priority"]?.stringValue ?? "balanced"
        guard let priority = WorkloadSpec.Priority(rawValue: priorityRaw) else {
            throw OCREngineError(engine: "mcp",
                                 message: "priority must be one of: quality, speed, balanced")
        }
        let needsMath = args["math"]?.boolValue ?? false
        let documentClassRaw = args["document_class"]?.stringValue ?? "unspecified"
        guard let documentClass = DocumentClass.parse(documentClassRaw) else {
            throw OCREngineError(engine: "mcp",
                                 message: "document_class must be one of: "
                                     + DocumentClass.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let gate = ocrGate
        let runLog = self.runLog
        let evidenceURL = self.evidenceURL
        let registrySnapshot = effectiveRegistry
        let work: @Sendable () async throws -> String = {
            try await gate.run {
                let summary: RunSummary
                if engineID == "auto" {
                    let evidence = try EvidenceStore.load(from: evidenceURL)
                    summary = try await RunPipeline.executeAuto(
                        inputPath: inputPath, dpi: dpi, pageSpec: pageSpec,
                        languages: languages, docType: docType,
                        priority: priority, needsMath: needsMath,
                        documentClass: documentClass,
                        outDir: URL(fileURLWithPath: outDir),
                        registry: registrySnapshot, evidence: evidence, runLog: runLog)
                } else {
                    summary = try await RunPipeline.execute(
                        inputPath: inputPath, engineID: engineID, dpi: dpi,
                        pageSpec: pageSpec, languages: languages, docType: docType,
                        outDir: URL(fileURLWithPath: outDir),
                        registry: registrySnapshot, runLog: runLog)
                }
                return Self.renderRunSummary(
                    summary: summary,
                    tradeoff: registrySnapshot.engine(id: summary.result.engineID)?.tradeoffNote)
            }
        }
        if args["async"]?.boolValue == true {
            let id = await jobs.start {
                do { return try await work() } catch let error as OCREngineError {
                    throw JobError(error.errorDescription ?? error.message)
                }
            }
            return "job started\njob_id: \(id)\npoll with ocr_status / ocr_result"
        }
        return try await work()
    }

    private func handleTriage(_ args: [String: Value]) async throws -> String {
        let inputPath = try requiredString("input_path", in: args)
        // Page-spec parsing mirrors TriageCommand: open the PDF for its real
        // page count so out-of-range pages are clamped here (a disjoint
        // selection then reaches TriageProbe.run's explicit empty-selection
        // guard instead of surviving as bogus page numbers). Unopenable PDFs
        // fall through as nil = all pages; run() reports its own degraded.
        let pages: [Int]? = args["pages"]?.stringValue.flatMap { spec -> [Int]? in
            guard !spec.isEmpty,
                  let doc = CGPDFDocument(URL(fileURLWithPath: inputPath) as CFURL),
                  doc.numberOfPages > 0 else { return nil }
            return InputNormalizer.parsePages(spec, count: doc.numberOfPages)
        }
        let divergence = args["divergence"]?.boolValue ?? false
        let report = try await TriageProbe.runComplete(
            inputPath: inputPath, pages: pages, divergence: divergence)
        let data = try JSONEncoder().encode(report)
        guard let json = String(data: data, encoding: .utf8) else {
            throw OCREngineError(engine: "mcp", message: "failed to encode triage report")
        }
        return json
    }

    private func handleRecommend(_ args: [String: Value]) throws -> String {
        let docType = try requiredString("doc_type", in: args)
        let priorityRaw = args["priority"]?.stringValue ?? "balanced"
        guard let priority = WorkloadSpec.Priority(rawValue: priorityRaw) else {
            throw OCREngineError(engine: "mcp",
                                 message: "priority must be one of: quality, speed, balanced")
        }
        let languages = (args["lang"]?.stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let documentClassRaw = args["document_class"]?.stringValue ?? "unspecified"
        guard let documentClass = DocumentClass.parse(documentClassRaw) else {
            throw OCREngineError(engine: "mcp",
                                 message: "document_class must be one of: "
                                     + DocumentClass.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let workload = WorkloadSpec(docType: docType, languages: languages,
                                    priority: priority,
                                    needsMath: args["math"]?.boolValue ?? false,
                                    documentClass: documentClass)
        let evidence = try EvidenceStore.load(from: evidenceURL)
        let answer = Recommender.recommend(workload: workload, registry: registry,
                                           evidence: evidence)
        var lines: [String] = []
        switch answer.mode {
        case .ranked(let tier):
            lines.append("RANKED (\(tier) evidence, priority: \(priority.rawValue), doc-type: \(docType))")
        case .evidencePending:
            lines.append("EVIDENCE-PENDING — no measured rows for this workload; this is a capability filter, not a ranking.")
        }
        if documentClass.requiresAssembly {
            lines.append("document-class \(documentClass.rawValue): candidates restricted to "
                + "document-assembly engines (slower than per-page — see each tradeoff).")
        }
        for (index, entry) in answer.entries.enumerated() {
            lines.append("  \(index + 1). \(entry.engineID) — \(entry.note)")
        }
        if answer.entries.isEmpty {
            lines.append("  (no engine satisfies this workload — nothing is being substituted for one that would)")
        }
        if !answer.citations.isEmpty {
            lines.append("evidence rows used: \(answer.citations.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    private func handleListEngines() async -> String {
        let probed = await registry.probeAll()
        let idWidth = max(probed.map { $0.engine.id.count }.max() ?? 0, 6)
        var lines = ["\("ENGINE".padding(toLength: idWidth, withPad: " ", startingAt: 0))  FAMILY             OUTPUT         ASSEMBLY       STATUS"]
        for (engine, availability) in probed {
            let status: String
            switch availability {
            case .available:
                status = "✓ available"
            case .unavailable(let reason, let hint):
                status = "✗ \(reason)" + (hint.map { " — install: \($0)" } ?? "")
            }
            let id = engine.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let family = engine.family.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)
            let output = engine.capabilities.outputLevel.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            let assembly = engine.capabilities.assembly.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            lines.append("\(id)  \(family)  \(output)  \(assembly)  \(status)")
            if let tradeoff = engine.tradeoffNote {
                lines.append("\(String(repeating: " ", count: idWidth))  ↳ tradeoff: \(tradeoff)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func renderModels() -> String {
        var lines = ["Admitted VLM model profiles (tiers in evidence/candidates.json):"]
        for profile in ModelProfile.all {
            let promptKind = profile.prompt == "OCR:" ? "native task prompt \"OCR:\""
                                                      : "shared instruction prompt"
            lines.append("  vlm.\(profile.id) — default tag \(profile.ollamaModel), "
                + "\(promptKind), output \(profile.outputLevel.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderRunSummary(summary: RunSummary, tradeoff: String? = nil) -> String {
        let pageCount = summary.result.pages.count
        let total = summary.result.pages.map(\.seconds).reduce(0, +)
        var lines: [String] = []
        // Routing notices explain which candidate list the trail below came from.
        lines.append(contentsOf: summary.notices.map { "ℹ \($0)" })
        // Fallback trail (auto mode) — every hop visible, never silent.
        for attempt in summary.attempts where attempt.failure != nil {
            lines.append("↷ \(attempt.engineID) skipped: \(attempt.failure!)")
        }
        lines.append(contentsOf: [
            "✓ \(summary.result.engineID): \(pageCount) page(s) in \(String(format: "%.1f", total))s",
            "markdown: \(summary.outputMarkdown.path)",
            "meta: \(summary.outputMeta.path)",
        ])
        if let structure = summary.result.document {
            lines.append("assembly: \(structure.blocks.count) block(s) in reading order")
            if let load = structure.loadSeconds {
                // Warm-model estimand: load is NOT inside the per-page times.
                lines.append("model load: \(String(format: "%.1f", load))s (excluded from per-page timing)")
            }
        }
        if let tradeoff { lines.append("tradeoff: \(tradeoff)") }
        if summary.result.pages.contains(where: \.degenerateFlagged) {
            lines.append("⚠ repetition guard tripped on at least one page — inspect the output")
        }
        return lines.joined(separator: "\n")
    }

    private func requiredString(_ key: String, in args: [String: Value]) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw OCREngineError(engine: "mcp", message: "missing required argument: \(key)")
        }
        return value
    }
}
