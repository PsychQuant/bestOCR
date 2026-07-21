import Foundation

/// External Python-tool engine speaking OCR protocol v1 (spec §5.4; bestASR
/// ExternalProcessEngine pattern). One instance per tool; the adapter script
/// owns the tool's runtime quirks, the host owns only the protocol.
public struct ExternalToolEngine: OCREngine {
    static let supportedProtocols: Set<Int> = [1]

    public let tool: String
    public let capabilities: EngineCapabilities
    public let installHint: String
    let pythonOverride: String?
    let scriptOverride: URL?
    let timeout: TimeInterval

    public var id: String { "ext.\(tool)" }
    public let family = EngineFamily.classical

    public init(tool: String, capabilities: EngineCapabilities, installHint: String,
                python: String? = nil, script: URL? = nil, timeout: TimeInterval = 300) {
        self.tool = tool
        self.capabilities = capabilities
        self.installHint = installHint
        self.pythonOverride = python
        self.scriptOverride = script
        self.timeout = timeout
    }

    /// `BESTOCR_PYTHON` env override, else `python3` from PATH.
    public static func locatePython() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BESTOCR_PYTHON"] {
            return FileManager.default.isExecutableFile(atPath: override)
                ? URL(fileURLWithPath: override) : nil
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/python3"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Materializes the embedded adapter script (single-binary distribution,
    /// M3): written to `BESTOCR_ADAPTER_DIR` or `~/.bestocr/adapters/`, and
    /// rewritten whenever the on-disk copy differs from the embedded source.
    func scriptURL() -> URL? {
        if let scriptOverride { return scriptOverride }
        guard let content = AdapterScripts.script(for: tool) else { return nil }
        let dirPath = ProcessInfo.processInfo.environment["BESTOCR_ADAPTER_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bestocr/adapters").path
        let dir = URL(fileURLWithPath: dirPath)
        let url = dir.appendingPathComponent("bestocr-\(tool)-adapter.py")
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return url
    }

    /// Protocol reads exactly one JSON object: the LAST stdout line that
    /// parses as JSON (download noise above it is ignored).
    static func lastJSONLine(_ stdout: String) -> Data? {
        for line in stdout.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            let data = Data(trimmed.utf8)
            if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        }
        return nil
    }

    struct ProbeReply: Decodable {
        let `protocol`: Int
        let ok: Bool
        let tool: String?
        let version: String?
        let reason: String?
    }

    struct OCRReply: Decodable {
        let `protocol`: Int
        let text: String
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
        let run: Subprocess.Result
        do {
            run = try Subprocess.run(python, arguments: [script.path, "probe"], timeout: 60)
        } catch {
            return .unavailable(reason: "probe failed: \(error.localizedDescription)",
                                installHint: installHint)
        }
        guard run.exitCode == 0,
              let data = Self.lastJSONLine(run.stdout),
              let reply = try? JSONDecoder().decode(ProbeReply.self, from: data) else {
            let tail = run.stderr.suffix(200).trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: "probe exited \(run.exitCode) without a protocol reply\(tail.isEmpty ? "" : ": \(tail)")",
                                installHint: installHint)
        }
        guard Self.supportedProtocols.contains(reply.protocol) else {
            return .unavailable(reason: "unsupported adapter protocol v\(reply.protocol)",
                                installHint: nil)
        }
        guard reply.ok else {
            return .unavailable(reason: reply.reason ?? "tool import failed",
                                installHint: installHint)
        }
        return .available
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        guard let python = Self.locatePython() else {
            throw OCREngineError(engine: id, message: "python3 not found on PATH")
        }
        guard let script = scriptURL() else {
            throw OCREngineError(engine: id, message: "adapter script missing from bundle")
        }
        var pageResults: [PageResult] = []
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
            pageResults.append(PageResult(page: page.pageNumber, text: reply.text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: tool, quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "python",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
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

    public static func surya() -> ExternalToolEngine {
        ExternalToolEngine(
            tool: "surya",
            capabilities: EngineCapabilities(outputLevel: .plainText,
                                             languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                                             needsNetwork: false, memoryClass: .medium),
            installHint: "pip install surya-ocr")
    }
}
