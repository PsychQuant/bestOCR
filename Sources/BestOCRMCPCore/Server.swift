import BestOCRKit
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
                    ]),
                    "required": .array([.string("doc_type")]),
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "consensus",
                description: "Multi-engine consensus OCR: run several engines over the same "
                    + "input, align items (line-primary, table cells split), adjudicate with "
                    + "a Dawid-Skene-lite estimator. Writes <stem>.consensus.md (⚠ marks "
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
        case "consensus":
            return try await handleConsensus(args)
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
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let engineIDs = (args["engines"]?.stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

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
                    runLog: runLogSnapshot)
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
            lines.append("skipped: \(id) — \(reason)")
        }
        let est = summary.estimate
        lines.append("items: \(est.items.count) (\(est.items.filter(\.lowConsensus).count) low-consensus) — \(est.iterations) iterations")
        for (id, c) in est.overallCompetence.sorted(by: { $0.value > $1.value }) {
            lines.append(String(format: "competence: %@ %.3f", id, c))
        }
        lines.append("transcript: \(summary.outputMarkdown.path)")
        lines.append("report: \(summary.outputReport.path)")
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
            .map { $0.trimmingCharacters(in: .whitespaces) }
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
                        outDir: URL(fileURLWithPath: outDir),
                        registry: registrySnapshot, evidence: evidence, runLog: runLog)
                } else {
                    summary = try await RunPipeline.execute(
                        inputPath: inputPath, engineID: engineID, dpi: dpi,
                        pageSpec: pageSpec, languages: languages, docType: docType,
                        outDir: URL(fileURLWithPath: outDir),
                        registry: registrySnapshot, runLog: runLog)
                }
                return Self.renderRunSummary(summary: summary)
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

    private func handleRecommend(_ args: [String: Value]) throws -> String {
        let docType = try requiredString("doc_type", in: args)
        let priorityRaw = args["priority"]?.stringValue ?? "balanced"
        guard let priority = WorkloadSpec.Priority(rawValue: priorityRaw) else {
            throw OCREngineError(engine: "mcp",
                                 message: "priority must be one of: quality, speed, balanced")
        }
        let languages = (args["lang"]?.stringValue ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let workload = WorkloadSpec(docType: docType, languages: languages,
                                    priority: priority,
                                    needsMath: args["math"]?.boolValue ?? false)
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
        for (index, entry) in answer.entries.enumerated() {
            lines.append("  \(index + 1). \(entry.engineID) — \(entry.note)")
        }
        if !answer.citations.isEmpty {
            lines.append("evidence rows used: \(answer.citations.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    private func handleListEngines() async -> String {
        let probed = await registry.probeAll()
        let idWidth = max(probed.map { $0.engine.id.count }.max() ?? 0, 6)
        var lines = ["\("ENGINE".padding(toLength: idWidth, withPad: " ", startingAt: 0))  FAMILY           OUTPUT         STATUS"]
        for (engine, availability) in probed {
            let status: String
            switch availability {
            case .available:
                status = "✓ available"
            case .unavailable(let reason, let hint):
                status = "✗ \(reason)" + (hint.map { " — install: \($0)" } ?? "")
            }
            let id = engine.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let family = engine.family.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
            let output = engine.capabilities.outputLevel.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            lines.append("\(id)  \(family)  \(output)  \(status)")
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

    static func renderRunSummary(summary: RunSummary) -> String {
        let pageCount = summary.result.pages.count
        let total = summary.result.pages.map(\.seconds).reduce(0, +)
        var lines: [String] = []
        // Fallback trail (auto mode) — every hop visible, never silent.
        for attempt in summary.attempts where attempt.failure != nil {
            lines.append("↷ \(attempt.engineID) skipped: \(attempt.failure!)")
        }
        lines.append(contentsOf: [
            "✓ \(summary.result.engineID): \(pageCount) page(s) in \(String(format: "%.1f", total))s",
            "markdown: \(summary.outputMarkdown.path)",
            "meta: \(summary.outputMeta.path)",
        ])
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
