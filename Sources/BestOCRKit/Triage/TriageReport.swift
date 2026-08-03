import Foundation

/// Measurement-based triage report: per-page text-layer / structure findings
/// plus a recommended execution route. Triage MEASURES and RECOMMENDS — it
/// never executes a path; the caller (CLI user, MCP client, or the ocr skill)
/// decides. JSON field names are a published contract shared byte-identically
/// by the CLI `--json` output and the MCP `triage` tool.
public struct TriageReport: Codable, Sendable, Equatable {

    /// Per-page measurements. The page-level verdict is authoritative; the
    /// file-level `route` is derived by aggregation and never overwrites it
    /// (hybrid documents are the failure class this prevents).
    public struct PageMeasure: Codable, Sendable, Equatable {
        public let page: Int
        public let textChars: Int
        public let hasTextLayer: Bool
        public let fragmentRatio: Double
        public let suspect: Bool

        public init(page: Int, textChars: Int, hasTextLayer: Bool,
                    fragmentRatio: Double, suspect: Bool) {
            self.page = page
            self.textChars = textChars
            self.hasTextLayer = hasTextLayer
            self.fragmentRatio = fragmentRatio
            self.suspect = suspect
        }

        enum CodingKeys: String, CodingKey {
            case page
            case textChars = "text_chars"
            case hasTextLayer = "has_text_layer"
            case fragmentRatio = "fragment_ratio"
            case suspect
        }
    }

    /// Divergence between extraction methods (Task 3). nil = measurement did
    /// not run — the JSON key is absent, never an empty object (nil = no such
    /// concept; [:] = ran with nothing to report — P12 discipline).
    public struct Divergence: Codable, Sendable, Equatable {
        public let informants: [String]
        public let perPage: [String: Double]

        public init(informants: [String], perPage: [String: Double]) {
            self.informants = informants
            self.perPage = perPage
        }

        enum CodingKeys: String, CodingKey {
            case informants
            case perPage = "per_page"
        }
    }

    /// Explicit degradation: measurement could not run (missing tool). Route
    /// falls back to `ocr_full` — behaviour identical to the pre-triage
    /// pipeline — and every surface must relay reason + install hint.
    public struct Degraded: Codable, Sendable, Equatable {
        public let reason: String
        public let installHint: String

        public init(reason: String, installHint: String) {
            self.reason = reason
            self.installHint = installHint
        }

        enum CodingKeys: String, CodingKey {
            case reason
            case installHint = "install_hint"
        }
    }

    /// Effective thresholds AFTER environment overrides — the report always
    /// discloses the values that actually gated its verdicts.
    public struct Thresholds: Codable, Sendable, Equatable {
        public let textCharsMin: Int
        public let fragmentRatioMax: Double

        public init(textCharsMin: Int, fragmentRatioMax: Double) {
            self.textCharsMin = textCharsMin
            self.fragmentRatioMax = fragmentRatioMax
        }

        enum CodingKeys: String, CodingKey {
            case textCharsMin = "text_chars_min"
            case fragmentRatioMax = "fragment_ratio_max"
        }
    }

    public enum Route: String, Codable, Sendable {
        case textDirect = "text_direct"
        case renderSuspectPages = "render_suspect_pages"
        case ocrFull = "ocr_full"
        case mixed
    }

    public let pages: [PageMeasure]
    public let suspectPages: [Int]
    public let divergence: Divergence?
    public let route: Route
    public let perPageRoutes: [String: String]
    public let thresholds: Thresholds
    public let degraded: Degraded?

    public init(pages: [PageMeasure], suspectPages: [Int], divergence: Divergence?,
                route: Route, perPageRoutes: [String: String], thresholds: Thresholds,
                degraded: Degraded?) {
        self.pages = pages
        self.suspectPages = suspectPages
        self.divergence = divergence
        self.route = route
        self.perPageRoutes = perPageRoutes
        self.thresholds = thresholds
        self.degraded = degraded
    }

    enum CodingKeys: String, CodingKey {
        case pages
        case suspectPages = "suspect_pages"
        case divergence
        case route
        case perPageRoutes = "per_page_routes"
        case thresholds
        case degraded
    }
}
