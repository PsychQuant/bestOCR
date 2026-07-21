import Foundation
import OCRCore

/// Local VLM engine over the Ollama HTTP API, wrapping ocr-swift's
/// OllamaBackend (spec §5.4). One VLMEngine instance per model profile.
public struct VLMEngine: OCREngine {
    public let profile: ModelProfile
    public let host: String
    public let modelOverride: String?
    let fuse = RepetitionGuard()

    public var id: String { "vlm.\(profile.id)" }
    public let family = EngineFamily.localVLM

    public var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: profile.outputLevel,
                           languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                           needsNetwork: false,   // localhost server, not internet
                           memoryClass: .medium)
    }

    public var resolvedModelTag: String { modelOverride ?? profile.ollamaModel }

    public init(profile: ModelProfile, host: String = "localhost:11434",
                modelOverride: String? = nil) {
        self.profile = profile
        self.host = host
        self.modelOverride = modelOverride
    }

    /// GET /api/tags: distinguishes server-down from model-missing so the
    /// install hint is actionable (spec §8).
    public func probe() async -> EngineAvailability {
        guard let url = URL(string: "http://\(host)/api/tags") else {
            return .unavailable(reason: "invalid Ollama host \(host)", installHint: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            return .unavailable(reason: "Ollama server unreachable at \(host)",
                                installHint: "ollama serve")
        }
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else {
            return .unavailable(reason: "Ollama at \(host) returned an unexpected /api/tags payload",
                                installHint: nil)
        }
        let wanted = resolvedModelTag
        let present = tags.models.contains {
            $0.name == wanted || $0.name.hasPrefix("\(wanted):")
        }
        guard present else {
            return .unavailable(reason: "model '\(wanted)' not present in Ollama",
                                installHint: "ollama pull \(wanted)  (or ollama create — see evidence/candidates.json)")
        }
        return .available
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        let backend = OllamaBackend(host: host, model: resolvedModelTag, prompt: profile.prompt)
        var pageResults: [PageResult] = []
        for page in request.pages {
            let data: Data
            do {
                data = try Data(contentsOf: page.url)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): cannot read \(page.url.path)")
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            let raw: String
            do {
                raw = try await backend.processImage(data)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            let (text, flagged) = postprocess(raw)
            if flagged {
                FileHandle.standardError.write(Data("[\(id)] page \(page.pageNumber): repetition guard tripped\n".utf8))
            }
            pageResults.append(PageResult(page: page.pageNumber, text: text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: flagged))
        }
        let condition = ConditionTuple(model: resolvedModelTag, quant: quantLabel(),
                                       dpi: request.dpi, docType: request.docType,
                                       platform: "ollama",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }

    /// Post-generation shaping shared by every page: profile-gated Y3
    /// delimiter normalization, then the repetition-guard marker (the fuse
    /// reads the raw text — normalization must not mask a degenerate loop).
    func postprocess(_ raw: String) -> (text: String, flagged: Bool) {
        let flagged = fuse.flags(raw)
        var text = profile.normalizesMathDelimiters
            ? MathDelimiterNormalizer.normalize(raw) : raw
        if flagged {
            text += "\n<!-- WARN: repetition-guard tripped — output may be degenerate -->"
        }
        return (text, flagged)
    }

    /// Quant from the Ollama tag suffix ("glm-ocr-anova:q4_K_M" → "q4_K_M");
    /// untagged models report "default" (the tag's build decides).
    func quantLabel() -> String {
        let tag = resolvedModelTag
        guard let colon = tag.firstIndex(of: ":") else { return "default" }
        return String(tag[tag.index(after: colon)...])
    }
}
