import Foundation

/// How a version was obtained (engine-version-provenance spec).
///
/// The value matters as much as the version itself: `probed` and
/// `adapterReported` do not carry the same weight when deciding whether two
/// readings count as independent evidence. An adapter's self-reported version
/// cannot be verified by bestOCR — it may have been read from a different
/// interpreter than the one that actually ran — so it is labelled rather than
/// silently trusted.
public enum VersionResolution: String, Sendable, Codable {
    /// Declared by the engine itself, e.g. a version bound to the OS.
    case declared
    /// Probed at run time, e.g. by executing a CLI.
    case probed = "probed"
    /// Reported by an adapter process; bestOCR cannot verify it.
    case adapterReported = "adapter_reported"
    /// Could not be obtained.
    case unavailable
}

/// The version of the tool that produced a result, plus how it was obtained.
///
/// There is deliberately no "primary version" field. Which component counts as
/// primary is a consumer-side judgement — an analysis comparing surya releases
/// and one comparing torch releases would answer differently — so fixing it
/// here would be a premature decision by the producer.
///
/// When no version can be obtained, `components` is empty and `resolution` is
/// `.unavailable`. An empty mapping already says "no version information", so
/// no separate sentinel string is needed.
public struct EngineVersion: Sendable, Codable, Equatable {
    /// Component name to version, e.g. `["surya-ocr": "0.22.1"]`. May carry
    /// several entries when one engine stacks multiple versioned pieces.
    public let components: [String: String]
    public let resolution: VersionResolution

    public init(components: [String: String], resolution: VersionResolution) {
        self.components = components
        self.resolution = resolution
    }

    /// The absence case, stated once so engines do not each spell it out.
    public static let unavailable = EngineVersion(components: [:], resolution: .unavailable)

    /// Convenience for the common single-component case.
    public static func single(_ name: String, _ version: String,
                              resolution: VersionResolution) -> EngineVersion {
        EngineVersion(components: [name: version], resolution: resolution)
    }

    /// Flattened for the legacy `ConditionTuple.toolVersion` string field,
    /// which predates this type (#28) and stays a string so archived rows keep
    /// decoding. Returns nil when nothing was obtained, so the legacy field
    /// keeps meaning "unknown" rather than gaining a placeholder value.
    public var legacyToolVersion: String? {
        guard !components.isEmpty else { return nil }
        return components.keys.sorted()
            .map { "\($0) \(components[$0]!)" }
            .joined(separator: "; ")
    }
}
