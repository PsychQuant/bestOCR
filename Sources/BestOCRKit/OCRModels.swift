import Foundation

/// A single normalized page image (spec §5.2: engines only ever see these).
public struct PageImage: Sendable {
    public let pageNumber: Int
    public let url: URL

    public init(pageNumber: Int, url: URL) {
        self.pageNumber = pageNumber
        self.url = url
    }
}

/// Input to `OCREngine.recognize` after normalization.
public struct OCRRequest: Sendable {
    public let pages: [PageImage]
    public let languages: [String]   // preference; engines map to their own codes
    public let dpi: Double?          // render DPI; nil when input was a raw image
    public let docType: String       // caller-declared workload label for the condition tuple

    public init(pages: [PageImage], languages: [String] = [], dpi: Double? = nil, docType: String = "unspecified") {
        self.pages = pages
        self.languages = languages
        self.dpi = dpi
        self.docType = docType
    }
}

/// Per-page output with provenance (spec §5.3).
public struct PageResult: Sendable, Codable {
    public let page: Int
    public let text: String
    public let seconds: Double
    public let thermalState: String
    public let degenerateFlagged: Bool

    public init(page: Int, text: String, seconds: Double, thermalState: String, degenerateFlagged: Bool) {
        self.page = page
        self.text = text
        self.seconds = seconds
        self.thermalState = thermalState
        self.degenerateFlagged = degenerateFlagged
    }
}

/// evidence/schema.md §3 — full condition tuple; JSON keys match verbatim.
public struct ConditionTuple: Sendable, Codable {
    public let model: String
    public let quant: String       // "n/a" for non-quantised engines
    public let dpi: Double?
    public let docType: String
    public let platform: String    // "vision" / "tesseract" / "ollama"
    public let hardware: String
    public let instrument: String
    /// The measuring tool's own version (#28) — for adapter-backed engines,
    /// reported by the process that produced the output. `instrument` is
    /// bestOCR's version and cannot stand in for it: `surya` 0.17.x and 0.22.x
    /// are different systems sharing a name, and without this field their rows
    /// are indistinguishable. Optional and additive, so every committed row
    /// keeps decoding (same precedent as `OCRResult.document`, #16).
    public let toolVersion: String?

    enum CodingKeys: String, CodingKey {
        case model, quant, dpi, platform, hardware, instrument
        case docType = "doc_type"
        case toolVersion = "tool_version"
    }

    public init(model: String, quant: String, dpi: Double?, docType: String,
                platform: String, hardware: String, instrument: String,
                toolVersion: String? = nil) {
        self.model = model
        self.quant = quant
        self.dpi = dpi
        self.docType = docType
        self.platform = platform
        self.hardware = hardware
        self.instrument = instrument
        self.toolVersion = toolVersion
    }
}

/// Unified engine output (spec §5.3): pages + condition tuple, plus the
/// optional document structure an assembly engine produces.
public struct OCRResult: Sendable, Codable {
    public let engineID: String
    public let pages: [PageResult]
    public let condition: ConditionTuple
    /// Non-nil only for engines whose `capabilities.assembly != .none`
    /// (document-assembly spec §4.2). Per-page engines leave it nil and lose
    /// nothing; being optional is also what keeps every already-archived
    /// `*.meta.json` decodable.
    public let document: DocumentStructure?

    public init(engineID: String, pages: [PageResult], condition: ConditionTuple,
                document: DocumentStructure? = nil) {
        self.engineID = engineID
        self.pages = pages
        self.condition = condition
        self.document = document
    }

    /// All page text joined; not encoded (derived).
    public var text: String { pages.map(\.text).joined(separator: "\n\n") }
}
