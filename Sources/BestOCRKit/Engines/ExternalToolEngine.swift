import Foundation

/// External Python-tool engine speaking OCR protocol v1 (spec §5.4; bestASR
/// ExternalProcessEngine pattern). One instance per tool; the adapter script
/// owns the tool's runtime quirks, the host owns only the protocol.
public struct ExternalToolEngine: OCREngine {
    static let supportedProtocols: Set<Int> = [1]

    public let tool: String
    public let capabilities: EngineCapabilities
    public let installHint: String
    /// Optional honest tradeoff/decision label (protocol requirement witness);
    /// travels with the engine into `list-engines` and `recommend`.
    public let tradeoffNote: String?
    let pythonOverride: String?
    let scriptOverride: URL?
    let timeout: TimeInterval

    public var id: String { "ext.\(tool)" }
    public let family = EngineFamily.classical

    public init(tool: String, capabilities: EngineCapabilities, installHint: String,
                tradeoffNote: String? = nil,
                python: String? = nil, script: URL? = nil, timeout: TimeInterval = 300) {
        self.tool = tool
        self.capabilities = capabilities
        self.installHint = installHint
        self.tradeoffNote = tradeoffNote
        self.pythonOverride = python
        self.scriptOverride = script
        self.timeout = timeout
    }

    /// `BESTOCR_PYTHON` env override, else `python3` from PATH.
    public static func locatePython() -> URL? { AdapterProtocolV1.locatePython() }

    /// Materializes the embedded adapter script (single-binary distribution, M3).
    func scriptURL() -> URL? {
        if let scriptOverride { return scriptOverride }
        guard let content = AdapterScripts.script(for: tool) else { return nil }
        return AdapterProtocolV1.materialize(content, tool: tool)
    }

    /// Protocol reads exactly one JSON object: the LAST stdout line that
    /// parses as JSON (download noise above it is ignored).
    static func lastJSONLine(_ stdout: String) -> Data? {
        AdapterProtocolV1.lastJSONLine(stdout)
    }

    struct OCRReply: Decodable {
        let `protocol`: Int
        let text: String
        /// The tool's own version, reported by the process that did the work
        /// (#28). Optional: old adapters and script overrides stay valid.
        let version: String?
    }

    public func probe() async -> EngineAvailability {
        guard let python = Self.locatePython() else {
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

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        guard let python = Self.locatePython() else {
            throw OCREngineError(engine: id, message: "python3 not found on PATH")
        }
        guard let script = scriptURL() else {
            throw OCREngineError(engine: id, message: "adapter script missing from bundle")
        }
        var pageResults: [PageResult] = []
        var toolVersion: String?
        for page in request.pages {
            var arguments = [script.path, "ocr", "--image", page.url.path]
            if !request.languages.isEmpty {
                arguments += ["--lang", request.languages.joined(separator: ",")]
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            let run: Subprocess.Result
            do {
                run = try Subprocess.run(python, arguments: arguments, timeout: timeout)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            guard run.exitCode == 0 else {
                let tail = run.stderr.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines)
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): adapter exit \(run.exitCode): \(tail)")
            }
            guard let data = Self.lastJSONLine(run.stdout),
                  let reply = try? JSONDecoder().decode(OCRReply.self, from: data),
                  Self.supportedProtocols.contains(reply.protocol) else {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): no protocol-v1 JSON on adapter stdout")
            }
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            if toolVersion == nil { toolVersion = reply.version }
            pageResults.append(PageResult(page: page.pageNumber, text: reply.text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: tool, quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "python",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string,
                                       toolVersion: toolVersion)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }
}

// MARK: - Standard tool wirings (roster entries; capabilities per tool)

extension ExternalToolEngine {
    public static func rapidocr() -> ExternalToolEngine {
        ExternalToolEngine(
            tool: "rapidocr",
            capabilities: EngineCapabilities(outputLevel: .plainText,
                                             languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                                             needsNetwork: false, memoryClass: .light),
            installHint: "pip install rapidocr")
    }

    public static func cnocr() -> ExternalToolEngine {
        ExternalToolEngine(
            tool: "cnocr",
            capabilities: EngineCapabilities(outputLevel: .plainText,
                                             languages: ["zh-Hans", "zh-Hant", "en"],
                                             needsNetwork: false, memoryClass: .light),
            installHint: "pip install cnocr[ort-cpu]")
    }

    /// Deliberately pinned to the surya-ocr 0.17.x generation (#29): the
    /// classical det+rec pipeline is self-contained — no model server — which
    /// makes this the roster's fallback that stays standing when the
    /// llama-server path breaks (#15). surya-2 (0.22.x) is a 0.65B VLM needing
    /// a served model: a DIFFERENT architecture, tracked as its own candidate
    /// in evidence/candidates.json, not an upgrade of this engine.
    public static func surya() -> ExternalToolEngine {
        ExternalToolEngine(
            tool: "surya",
            capabilities: EngineCapabilities(outputLevel: .plainText,
                                             languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                                             needsNetwork: false, memoryClass: .medium),
            installHint: "pip install \"surya-ocr<0.20\"  (0.17.x generation — see tradeoff)",
            tradeoffNote: "deliberately pinned to the surya-ocr 0.17.x classical det+rec generation — self-contained, no model server, so it survives llama-server breakage (#15). surya-2 (0.22.x) is a different architecture (0.65B VLM behind llama-server/vllm) and is a separate engine candidate (#29), not an upgrade of this one")
    }

    /// Asks the adapter for its version without running OCR. The same value
    /// also reaches the condition tuple during recognition; this method is the
    /// answer available before any page is read.
    public func resolveVersion() async -> EngineVersion {
        guard let python = Self.locatePython(),
              let script = scriptURL() else { return .unavailable }
        return AdapterProtocolV1.probeVersion(python: python, script: script, tool: tool)
    }

}
