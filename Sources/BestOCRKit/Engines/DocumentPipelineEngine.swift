import Foundation

/// How an assembly adapter has to be driven. This is not a style choice — it is
/// the difference between a measured number and an invented one.
///
/// A tool exposing a Python pipeline object can load its models once and then
/// time each page **warm**, which is what `speed.ms_per_page@v1` is defined as.
/// A tool reachable only through a CLI reloads its models on every invocation,
/// so there is no warm per-page time to report; the host times each call and the
/// number honestly includes that reload. Dividing one batch wall-clock by the
/// page count would look like per-page timing while measuring nothing.
public enum AssembleInvocation: Sendable {
    /// One adapter call per page image; the HOST measures each call.
    case perPage
    /// One adapter call for every page; the ADAPTER reports warm per-page
    /// seconds plus its model-load time separately.
    case wholeDocument
}

/// A document-assembly engine speaking OCR protocol v1's `assemble` command
/// (document-assembly spec §8).
///
/// Spec §5.2 still holds: the adapter receives page *images*, never the PDF.
/// Cross-page assembly is therefore out of scope by construction — what these
/// engines add is *within-page* reading order and table structure, which is
/// exactly the failure #15 measured (headers interleaving mid-content).
public struct DocumentPipelineEngine: OCREngine {
    public let tool: String
    public let capabilities: EngineCapabilities
    public let installHint: String
    /// The honest per-engine tradeoff (spec §8), surfaced by `list-engines` and
    /// `recommend` so a correctness win never hides its cost.
    public let tradeoff: String
    public let invocation: AssembleInvocation
    let scriptOverride: URL?
    let timeout: TimeInterval

    public var id: String { "doc.\(tool)" }
    public let family = EngineFamily.documentPipeline
    public var tradeoffNote: String? { tradeoff }

    /// Assembly runs are minutes, not seconds — a per-page-style timeout would
    /// kill legitimate work. `BESTOCR_DOC_TIMEOUT` (seconds) overrides.
    public static var defaultTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["BESTOCR_DOC_TIMEOUT"]
            .flatMap(Double.init) ?? 1800
    }

    public init(tool: String, capabilities: EngineCapabilities, installHint: String,
                tradeoff: String, invocation: AssembleInvocation,
                script: URL? = nil, timeout: TimeInterval? = nil) {
        self.tool = tool
        self.capabilities = capabilities
        self.installHint = installHint
        self.tradeoff = tradeoff
        self.invocation = invocation
        self.scriptOverride = script
        self.timeout = timeout ?? Self.defaultTimeout
    }

    func scriptURL() -> URL? {
        if let scriptOverride { return scriptOverride }
        guard let content = DocumentAdapterScripts.script(for: tool) else { return nil }
        return AdapterProtocolV1.materialize(content, tool: tool)
    }

    public func probe() async -> EngineAvailability {
        guard let python = AdapterProtocolV1.locatePython() else {
            return .unavailable(reason: "python3 not found on PATH",
                                installHint: "install Python 3 or set BESTOCR_PYTHON")
        }
        guard let script = scriptURL() else {
            return .unavailable(reason: "adapter script for \(tool) missing from bundle",
                                installHint: nil)
        }
        return AdapterProtocolV1.probe(python: python, script: script, tool: tool,
                                       installHint: installHint)
    }

    // MARK: - Protocol v1 `assemble` reply

    struct AssembleReply: Decodable {
        struct Page: Decodable {
            let page: Int          // 1-based index into the images sent in THIS call
            let text: String
            /// Warm per-page seconds. Required in `.wholeDocument` mode, absent
            /// in `.perPage` mode where the host does the timing.
            let seconds: Double?
        }

        struct Block: Decodable {
            let page: Int
            let kind: String
            let text: String
            let bbox: BoundingBox?
        }

        let `protocol`: Int
        let loadSeconds: Double?
        /// The tool's own version, reported by the process that did the work
        /// (#28). Optional for old adapters.
        let version: String?
        let pages: [Page]
        let blocks: [Block]

        enum CodingKeys: String, CodingKey {
            case `protocol`, pages, blocks, version
            case loadSeconds = "load_seconds"
        }
    }

    // MARK: - Recognize

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        guard let python = AdapterProtocolV1.locatePython() else {
            throw OCREngineError(engine: id, message: "python3 not found on PATH")
        }
        guard let script = scriptURL() else {
            throw OCREngineError(engine: id, message: "adapter script missing from bundle")
        }
        guard !request.pages.isEmpty else {
            throw OCREngineError(engine: id, message: "no pages to assemble")
        }

        switch invocation {
        case .wholeDocument:
            let reply = try assemble(python: python, script: script,
                                     images: request.pages.map(\.url.path),
                                     languages: request.languages)
            return try wholeDocumentResult(reply: reply, request: request)
        case .perPage:
            return try perPageResult(python: python, script: script, request: request)
        }
    }

    func assemble(python: URL, script: URL, images: [String],
                  languages: [String]) throws -> AssembleReply {
        var arguments = [script.path, "assemble"]
        for image in images { arguments += ["--image", image] }
        if !languages.isEmpty { arguments += ["--lang", languages.joined(separator: ",")] }

        let run: Subprocess.Result
        do {
            run = try Subprocess.run(python, arguments: arguments, timeout: timeout)
        } catch {
            throw OCREngineError(engine: id, message: error.localizedDescription)
        }
        guard run.exitCode == 0 else {
            let tail = run.stderr.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines)
            throw OCREngineError(engine: id, message: "adapter exit \(run.exitCode): \(tail)")
        }
        guard let data = AdapterProtocolV1.lastJSONLine(run.stdout),
              let reply = try? JSONDecoder().decode(AssembleReply.self, from: data),
              AdapterProtocolV1.supportedProtocols.contains(reply.protocol) else {
            throw OCREngineError(engine: id,
                                 message: "no protocol-v1 assemble JSON on adapter stdout")
        }
        return reply
    }

    /// Adapters index the images 1…N in the order they were handed over; the
    /// host owns the real page numbers (a `--pages 3-5` run starts at 3), so
    /// the mapping lives here and the adapter stays dumb.
    func actualPage(_ index: Int, in pageNumbers: [Int]) throws -> Int {
        guard index >= 1, index <= pageNumbers.count else {
            throw OCREngineError(engine: id,
                                 message: "adapter reported page index \(index) outside 1…\(pageNumbers.count)")
        }
        return pageNumbers[index - 1]
    }

    func wholeDocumentResult(reply: AssembleReply, request: OCRRequest) throws -> OCRResult {
        let pageNumbers = request.pages.map(\.pageNumber)
        // A silently dropped page would look like a shorter document rather
        // than a failure, so the page set must be exactly what we sent.
        guard Set(reply.pages.map(\.page)) == Set(1...pageNumbers.count) else {
            throw OCREngineError(engine: id,
                                 message: "adapter returned \(reply.pages.count) page record(s) for \(pageNumbers.count) image(s)")
        }
        let thermal = HostInfo.thermalLabel()
        let pages = try reply.pages.sorted { $0.page < $1.page }.map { page in
            guard let seconds = page.seconds else {
                throw OCREngineError(engine: id,
                                     message: "adapter omitted warm per-page seconds (required in whole-document mode — the host cannot infer them without inventing a number)")
            }
            return PageResult(page: try actualPage(page.page, in: pageNumbers),
                              text: page.text, seconds: seconds,
                              thermalState: thermal, degenerateFlagged: false)
        }
        let blocks = try reply.blocks.map {
            DocumentBlock(page: try actualPage($0.page, in: pageNumbers),
                          kind: BlockKind(rawValue: $0.kind) ?? .other,
                          text: $0.text, bbox: $0.bbox)
        }
        return try finish(pages: pages, blocks: blocks,
                          loadSeconds: reply.loadSeconds,
                          toolVersion: reply.version, request: request)
    }

    func perPageResult(python: URL, script: URL, request: OCRRequest) throws -> OCRResult {
        var pages: [PageResult] = []
        var blocks: [DocumentBlock] = []
        var toolVersion: String?
        for page in request.pages {
            let t0 = ProcessInfo.processInfo.systemUptime
            let reply = try assemble(python: python, script: script,
                                     images: [page.url.path],
                                     languages: request.languages)
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            if toolVersion == nil { toolVersion = reply.version }
            guard reply.pages.count == 1 else {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): adapter returned \(reply.pages.count) page records for one image")
            }
            pages.append(PageResult(page: page.pageNumber, text: reply.pages[0].text,
                                    seconds: seconds,
                                    thermalState: HostInfo.thermalLabel(),
                                    degenerateFlagged: false))
            blocks += reply.blocks.map {
                DocumentBlock(page: page.pageNumber,
                              kind: BlockKind(rawValue: $0.kind) ?? .other,
                              text: $0.text, bbox: $0.bbox)
            }
        }
        // No separable load time: this tool reloads per invocation, and that
        // cost is already inside each page's measured seconds.
        return try finish(pages: pages, blocks: blocks, loadSeconds: nil,
                          toolVersion: toolVersion, request: request)
    }

    func finish(pages: [PageResult], blocks: [DocumentBlock],
                loadSeconds: Double?, toolVersion: String?,
                request: OCRRequest) throws -> OCRResult {
        let condition = ConditionTuple(model: tool, quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "python",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string,
                                       toolVersion: toolVersion)
        let result = OCRResult(engineID: id, pages: pages, condition: condition,
                               document: DocumentStructure(blocks: blocks,
                                                           loadSeconds: loadSeconds))
        // Spec §4.3: the adapter derives each page's text from that page's
        // blocks, so a mismatch is our own adapter losing content. Failing loudly
        // lets auto-routing fall back with the hop printed; passing it through
        // would ship a plausible-looking transcript with holes in it.
        guard result.documentContentMatchesPages else {
            throw OCREngineError(engine: id,
                                 message: "assembly invariant violated — block text and page text carry different content (spec §4.3)")
        }
        return result
    }
}

// MARK: - Roster entries (document-assembly spec §8)

extension DocumentPipelineEngine {
    /// PP-DocLayoutV2 layout detection → crop → VL recognition → assemble.
    /// Chosen for Apple Silicon because the layout model is a **detection**
    /// model and never touches llama.cpp's `json_schema` → GBNF path — the path
    /// that breaks marker's *balanced-mode* layout (#15).
    public static func paddleOCRPipeline() -> DocumentPipelineEngine {
        DocumentPipelineEngine(
            tool: "paddleocr-pipeline",
            capabilities: EngineCapabilities(outputLevel: .markdown,
                                             languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                                             needsNetwork: false, memoryClass: .heavy,
                                             assembly: .fullStructure),
            installHint: "pip install \"paddleocr>=3.7\" paddlepaddle \"paddlex[ocr]\"",
            tradeoff: "correct reading order on Apple Silicon; CPU-only (no MPS) so substantially slower than the per-page Ollama path, heavier install, and can emit a multiple-choice block as one spurious table",
            invocation: .wholeDocument)
    }

    /// surya-2 + marker's assembly layer, driven through `marker_single`.
    ///
    /// Admitted at `.readingOrder`, not `.fullStructure`. The tradeoff label
    /// carries the platform caveat, because admitting an engine whose signature
    /// capability can degrade on the target platform is only defensible if the
    /// degradation travels with it.
    public static func marker() -> DocumentPipelineEngine {
        DocumentPipelineEngine(
            tool: "marker",
            capabilities: EngineCapabilities(outputLevel: .mathMarkdown,
                                             languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                                             needsNetwork: false, memoryClass: .heavy,
                                             assembly: .readingOrder),
            installHint: "uv tool install marker-pdf  (provides marker_single on PATH)",
            tradeoff: "best inline-math LaTeX of the engines compared in #15. Layout is only fragile in --mode balanced, whose VLM layout goes through llama.cpp's json_schema → GBNF path; the adapter lets marker take its device default (fast on Apple Silicon: CPU layout detectors, so layout stays OUT of the grammar path). Cost: marker_single reloads its models per page, so per-page seconds include that reload",
            invocation: .perPage)
    }
}
