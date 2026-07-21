import Foundation

/// Cloud vision engine — REFERENCE TIER ONLY (spec §5.4/§6.1.3): usable for
/// explicit runs and `compare`, never ranked by `recommend` (the Recommender
/// filters `.cloudReference`). Probe = API-key env presence; a missing key
/// never blocks any local flow.
public struct CloudReferenceEngine: OCREngine {
    public let provider: CloudProvider

    public var id: String { provider.id }
    public let family = EngineFamily.cloudReference

    public var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .markdown,
                           languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                           needsNetwork: true,
                           memoryClass: .light)
    }

    public init(provider: CloudProvider) {
        self.provider = provider
    }

    public func probe() async -> EngineAvailability {
        guard let key = ProcessInfo.processInfo.environment[provider.keyEnv], !key.isEmpty else {
            return .unavailable(reason: "\(provider.keyEnv) not set",
                                installHint: "export \(provider.keyEnv)=<key> (reference tier — documents leave the machine)")
        }
        return .available
    }

    static let prompt =
        "Transcribe this document page to Markdown. Reproduce headings, lists and tables; render math as LaTeX. Output only the transcription, no commentary."

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        guard let key = ProcessInfo.processInfo.environment[provider.keyEnv], !key.isEmpty else {
            throw OCREngineError(engine: id, message: "\(provider.keyEnv) not set")
        }
        var pageResults: [PageResult] = []
        for page in request.pages {
            let data: Data
            do {
                data = try Data(contentsOf: page.url)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): cannot read \(page.url.path)")
            }
            let mediaType = Self.mediaType(for: page.url)
            let urlRequest = provider.makeRequest(imageData: data, mediaType: mediaType,
                                                  prompt: Self.prompt, key: key)
            let t0 = ProcessInfo.processInfo.systemUptime
            let responseData: Data
            let response: URLResponse
            do {
                (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let tail = String(data: responseData.prefix(300), encoding: .utf8) ?? ""
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): HTTP \(http.statusCode): \(tail)")
            }
            let text = try provider.parseText(from: responseData)
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            pageResults.append(PageResult(page: page.pageNumber, text: text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: provider.resolvedModel, quant: "n/a",
                                       dpi: request.dpi, docType: request.docType,
                                       platform: provider.rawValue,
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }

    static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "image/png"   // PageRenderer emits PNG
        }
    }
}
