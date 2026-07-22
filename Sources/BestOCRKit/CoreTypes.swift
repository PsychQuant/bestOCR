import Foundation

/// bestOCR product version string, recorded as the `instrument` field of every
/// condition tuple (evidence/schema.md §3) until git-sha stamping arrives.
public enum BestOCRVersion {
    /// Plain semver for surfaces that require it (MCP server info, plugin.json).
    public static let semver = "0.5.1"
    /// Derived, never hand-written — a hardcoded copy drifted to "0.1.0-dev"
    /// while semver moved on, corrupting every evidence row's instrument
    /// field (#10).
    public static let string = "bestocr \(semver)"
}

/// Spec §5.1 — engine families. Cloud stays reference-only (spec §6.1.3).
public enum EngineFamily: String, Sendable, Codable {
    case localVLM = "local_vlm"
    case classical
    case cloudReference = "cloud_reference"
}

/// What fidelity of output an engine can produce.
public enum OutputLevel: String, Sendable, Codable {
    case plainText = "plain_text"
    case markdown
    case mathMarkdown = "math_markdown"
}

/// Rough unified-memory footprint class, for capability display and later filtering.
public enum MemoryClass: String, Sendable, Codable {
    case light      // <500 MB (Vision, tesseract)
    case medium     // 0.5–4 GB (0.9B-class VLM quants)
    case heavy      // >4 GB
}

/// Spec §5.1/§8 — probe result. Absence is a value, never an exception.
public enum EngineAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String, installHint: String?)
}

/// Spec §5.1 — declared capabilities used for display (M1) and filtering (M2).
public struct EngineCapabilities: Sendable {
    public let outputLevel: OutputLevel
    public let languages: [String]      // BCP-47-style: "en", "zh-Hant", "zh-Hans", "ja"
    public let needsNetwork: Bool
    public let memoryClass: MemoryClass

    public init(outputLevel: OutputLevel, languages: [String], needsNetwork: Bool, memoryClass: MemoryClass) {
        self.outputLevel = outputLevel
        self.languages = languages
        self.needsNetwork = needsNetwork
        self.memoryClass = memoryClass
    }
}

/// Spec §8 — every engine failure surfaces engine id + reason (never silent).
public struct OCREngineError: Error, LocalizedError {
    public let engine: String
    public let message: String

    public init(engine: String, message: String) {
        self.engine = engine
        self.message = message
    }

    public var errorDescription: String? { "[\(engine)] \(message)" }
}

/// Spec §5.1 — the common contract every OCR engine implements.
public protocol OCREngine: Sendable {
    var id: String { get }
    var family: EngineFamily { get }
    var capabilities: EngineCapabilities { get }
    /// Probes lazily and never throws — absence is reported as a value.
    func probe() async -> EngineAvailability
    func recognize(_ request: OCRRequest) async throws -> OCRResult
}
