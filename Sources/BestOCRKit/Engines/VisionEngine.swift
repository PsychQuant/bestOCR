import Foundation
import Vision

/// Apple Vision framework engine — in-process, zero-dependency, always
/// available on macOS (spec §5.4: screenshots, quick single images, zh-Hant/ja).
/// Uses VNRecognizeTextRequest for the macOS-14 floor; deprecation warnings
/// under newer SDKs are accepted for M1.
public struct VisionEngine: OCREngine {
    public let id = "vision"
    public let family = EngineFamily.classical

    public var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText,
                           languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                           needsNetwork: false,
                           memoryClass: .light)
    }

    public init() {}

    public func probe() async -> EngineAvailability {
        .available   // OS framework — present on every supported macOS
    }

    /// Map request languages to Vision codes; default favours the user's
    /// zh-Hant/ja/en daily mix.
    static func visionLanguages(_ languages: [String]) -> [String] {
        guard !languages.isEmpty else { return ["zh-Hant", "ja", "en-US"] }
        return languages.map { $0 == "en" ? "en-US" : $0 }
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        var pageResults: [PageResult] = []
        for page in request.pages {
            let t0 = ProcessInfo.processInfo.systemUptime
            let vnRequest = VNRecognizeTextRequest()
            vnRequest.recognitionLevel = .accurate
            vnRequest.usesLanguageCorrection = true
            vnRequest.recognitionLanguages = Self.visionLanguages(request.languages)
            let handler = VNImageRequestHandler(url: page.url)
            do {
                try handler.perform([vnRequest])
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            let text = (vnRequest.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            pageResults.append(PageResult(page: page.pageNumber, text: text,
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: "vision", quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "vision",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string,
                                       toolVersion: await resolveVersion().legacyToolVersion)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }

    /// Vision has no version of its own — it ships with the OS, so the OS
    /// version is the honest answer and it is `declared`, not probed.
    public func resolveVersion() async -> EngineVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return .single("macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                       resolution: .declared)
    }

}
