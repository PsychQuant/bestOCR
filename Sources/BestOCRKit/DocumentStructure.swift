import Foundation

/// Normalized page coordinates in `[0,1]`, origin top-left. Optional on a block
/// because not every assembly engine reports geometry (spec §12: making it
/// required would exclude engines that do not).
public struct BoundingBox: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The block vocabulary shared by every assembly engine. Adapters map their
/// upstream labels onto these; anything unmapped decodes as `.other` rather
/// than failing, so a new upstream label can never make an archived
/// `*.meta.json` unreadable.
public enum BlockKind: String, Sendable, Codable {
    case heading, paragraph, list, table, figure, formula, header, footer, other

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BlockKind(rawValue: raw) ?? .other
    }
}

/// One structural region of a document, in reading order (see
/// `DocumentStructure`).
public struct DocumentBlock: Sendable, Codable {
    public let page: Int
    public let kind: BlockKind
    /// This block's rendering — markdown for tables, LaTeX for formulas when
    /// the engine produces it.
    public let text: String
    public let bbox: BoundingBox?

    public init(page: Int, kind: BlockKind, text: String, bbox: BoundingBox? = nil) {
        self.page = page
        self.kind = kind
        self.text = text
        self.bbox = bbox
    }
}

/// Spec §4.2 — what an assembly engine adds over per-page transcription.
///
/// Reading order **is** the array order of `blocks`. There is deliberately no
/// separate order index: two representations of the same fact drift, and the
/// ordering is the whole product of the engine.
public struct DocumentStructure: Sendable, Codable {
    public let blocks: [DocumentBlock]
    /// Pipeline warm-up (model load), which `PageResult.seconds` deliberately
    /// EXCLUDES — `speed.ms_per_page@v1` is a warm-model estimand, so folding
    /// load time into page 1 would corrupt it. Recorded here so the cost is
    /// disclosed rather than lost.
    public let loadSeconds: Double?

    public init(blocks: [DocumentBlock], loadSeconds: Double? = nil) {
        self.blocks = blocks
        self.loadSeconds = loadSeconds
    }

    /// Reading-order rendering: blocks joined in array order.
    public var text: String { blocks.map(\.text).joined(separator: "\n\n") }
}

// MARK: - Spec §4.3 invariant

extension OCRResult {
    /// Content lines, normalized so that formatting differences (indentation,
    /// blank lines, runs of spaces) are not mistaken for lost content.
    static func contentLines(_ text: String) -> [String] {
        text.split(separator: "\n").map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
    }

    /// Spec §4.3 — when `document != nil`, the block sequence must carry the
    /// same *content* as the page sequence: same lines, possibly reordered.
    /// Reordering is the point of an assembly engine; losing or inventing
    /// content is a broken adapter, and this is the property that catches it.
    ///
    /// Vacuously true for per-page engines, which have no structure to check.
    public var documentContentMatchesPages: Bool {
        guard let document else { return true }
        let fromPages = Self.contentLines(pages.map(\.text).joined(separator: "\n"))
        let fromBlocks = Self.contentLines(document.text)
        return fromPages.sorted() == fromBlocks.sorted()
    }
}
