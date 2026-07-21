import Foundation

/// Classical OCR via the tesseract CLI (spec §5.4: scanned-book batches,
/// low memory). Integrated as a subprocess; probe reports the install hint.
public struct TesseractEngine: OCREngine {
    public let id = "tesseract"
    public let family = EngineFamily.classical
    let binaryPath: String?

    public var capabilities: EngineCapabilities {
        EngineCapabilities(outputLevel: .plainText,
                           languages: ["en", "zh-Hant", "zh-Hans", "ja"],
                           needsNetwork: false,
                           memoryClass: .light)
    }

    /// Pass `binaryPath` explicitly in tests; nil = search standard locations.
    public init(binaryPath: String? = nil) {
        self.binaryPath = binaryPath
    }

    /// Standard Homebrew / MacPorts / manual locations, then PATH.
    public static func locate() -> URL? {
        let candidates = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let path = "\(dir)/tesseract"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func resolvedBinary() -> URL? {
        if let binaryPath {
            return FileManager.default.isExecutableFile(atPath: binaryPath)
                ? URL(fileURLWithPath: binaryPath) : nil
        }
        return Self.locate()
    }

    /// BCP-47-ish → tesseract language codes; unknown codes fall back to eng.
    static func tesseractLanguages(_ languages: [String]) -> String {
        let map = ["en": "eng", "zh-Hant": "chi_tra", "zh-Hans": "chi_sim", "ja": "jpn"]
        let codes = languages.compactMap { map[$0] }
        return codes.isEmpty ? "eng" : codes.joined(separator: "+")
    }

    public func probe() async -> EngineAvailability {
        guard resolvedBinary() != nil else {
            return .unavailable(reason: "tesseract binary not found",
                                installHint: "brew install tesseract tesseract-lang")
        }
        return .available
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        guard let binary = resolvedBinary() else {
            throw OCREngineError(engine: id,
                                 message: "tesseract binary not found — brew install tesseract tesseract-lang")
        }
        let langs = Self.tesseractLanguages(request.languages)
        var pageResults: [PageResult] = []
        for page in request.pages {
            let t0 = ProcessInfo.processInfo.systemUptime
            let run: Subprocess.Result
            do {
                run = try Subprocess.run(binary, arguments: [page.url.path, "stdout", "-l", langs])
            } catch {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): \(error.localizedDescription)")
            }
            guard run.exitCode == 0 else {
                throw OCREngineError(engine: id,
                                     message: "page \(page.pageNumber): exit \(run.exitCode): \(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let seconds = ProcessInfo.processInfo.systemUptime - t0
            pageResults.append(PageResult(page: page.pageNumber,
                                          text: run.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                          seconds: seconds,
                                          thermalState: HostInfo.thermalLabel(),
                                          degenerateFlagged: false))
        }
        let condition = ConditionTuple(model: "tesseract", quant: "n/a", dpi: request.dpi,
                                       docType: request.docType, platform: "tesseract",
                                       hardware: HostInfo.hardwareLabel(),
                                       instrument: BestOCRVersion.string)
        return OCRResult(engineID: id, pages: pageResults, condition: condition)
    }
}
