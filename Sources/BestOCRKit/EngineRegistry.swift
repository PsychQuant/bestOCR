/// The engine roster (spec §4): construction is explicit so tests can inject
/// stubs; `standard()` is the production wiring used by the CLI.
public struct EngineRegistry: Sendable {
    public let engines: [any OCREngine]

    public init(engines: [any OCREngine]) {
        self.engines = engines
    }

    /// M2 roster: classical (Vision, tesseract, external Python tools) then
    /// one VLM engine per admitted profile.
    public static func standard(ollamaHost: String = "localhost:11434") -> EngineRegistry {
        var engines: [any OCREngine] = [
            VisionEngine(), TesseractEngine(),
            ExternalToolEngine.rapidocr(), ExternalToolEngine.cnocr(), ExternalToolEngine.surya(),
        ]
        engines.append(contentsOf: ModelProfile.all.map {
            VLMEngine(profile: $0, host: ollamaHost)
        })
        return EngineRegistry(engines: engines)
    }

    public func engine(id: String) -> (any OCREngine)? {
        engines.first { $0.id == id }
    }

    public func probeAll() async -> [(engine: any OCREngine, availability: EngineAvailability)] {
        var out: [(engine: any OCREngine, availability: EngineAvailability)] = []
        for engine in engines {
            out.append((engine, await engine.probe()))
        }
        return out
    }
}
