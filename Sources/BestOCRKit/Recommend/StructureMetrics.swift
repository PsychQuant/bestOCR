import Foundation

/// Text normalization shared by both assembly metrics: case-folded and
/// whitespace-collapsed, so formatting noise is never scored as a structural
/// error.
enum MetricText {
    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Dice coefficient over character bigrams — cheap, and forgiving of the
    /// single-character OCR slips that would break exact matching without
    /// meaning the block is a different block. Strings too short to have
    /// bigrams fall back to equality.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1.0 }
        let left = bigrams(lhs), right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0.0 }
        var shared = 0
        var pool = right
        for gram in left {
            if let index = pool.firstIndex(of: gram) {
                shared += 1
                pool.remove(at: index)
            }
        }
        return 2.0 * Double(shared) / Double(left.count + right.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }
}

/// `quality.reading_order_tau@v1` (evidence/schema.md §2) — how faithfully an
/// engine reproduced a reference reading order.
///
/// **Defined, unmeasured**: no annotated reference subset exists yet
/// (document-assembly spec §6.3), so this formula has no rows behind it. It is
/// implemented because a formula stated only in prose cannot be checked.
public enum ReadingOrderTau {
    /// Similarity at or above which two blocks are considered the same block.
    /// Part of the formula, so it is stated in `evidence/schema.md` too — a
    /// threshold changed silently would change the estimand.
    public static let matchThreshold = 0.6

    public struct Result: Sendable, Equatable {
        /// Kendall's tau-b over the matched subsequence. `nil` when fewer than
        /// two pairs matched: no correlation exists, and reporting 0 would
        /// assert "uncorrelated", which is a different claim from "unknown".
        public let tau: Double?
        public let matched: Int
        /// Blocks the engine produced that match no reference block, and
        /// reference blocks it missed. These are a DETECTION failure and are
        /// deliberately kept out of `tau`, which measures ORDERING only.
        public let unmatchedProduced: Int
        public let unmatchedReference: Int
    }

    public static func evaluate(produced: [DocumentBlock],
                               reference: [DocumentBlock]) -> Result {
        let producedText = produced.map { MetricText.normalize($0.text) }
        let referenceText = reference.map { MetricText.normalize($0.text) }

        // Greedy one-to-one matching in produced order; ties resolved by the
        // lowest reference index so the result is deterministic.
        var usedReference = Set<Int>()
        var referenceRanks: [Int] = []
        for text in producedText {
            var best: (index: Int, score: Double)?
            for (index, candidate) in referenceText.enumerated() where !usedReference.contains(index) {
                let score = MetricText.similarity(text, candidate)
                if score > (best?.score ?? -1) { best = (index, score) }
            }
            if let best, best.score >= matchThreshold {
                usedReference.insert(best.index)
                referenceRanks.append(best.index)
            }
        }

        return Result(tau: tauB(referenceRanks),
                      matched: referenceRanks.count,
                      unmatchedProduced: produced.count - referenceRanks.count,
                      unmatchedReference: reference.count - referenceRanks.count)
    }

    /// Kendall's tau-b of `ranks` against its own index order. Tie corrections
    /// are carried even though one-to-one matching cannot currently produce
    /// ties — the formula is the estimand, not the current caller.
    static func tauB(_ ranks: [Int]) -> Double? {
        let n = ranks.count
        guard n >= 2 else { return nil }
        var concordant = 0, discordant = 0, tiedX = 0, tiedY = 0
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                let dx = i - j                      // positions: never tied
                let dy = ranks[i] - ranks[j]
                if dx == 0 && dy == 0 { tiedX += 1; tiedY += 1 }
                else if dx == 0 { tiedX += 1 }
                else if dy == 0 { tiedY += 1 }
                else if (dx < 0) == (dy < 0) { concordant += 1 }
                else { discordant += 1 }
            }
        }
        let n0 = Double(n * (n - 1) / 2)
        let denominator = ((n0 - Double(tiedX)) * (n0 - Double(tiedY))).squareRoot()
        guard denominator > 0 else { return nil }
        return Double(concordant - discordant) / denominator
    }
}

/// `quality.table_structure_f1@v1` (evidence/schema.md §2) — cell-level F1 over
/// `(row, column, normalized text)` triples.
///
/// Cell-level rather than whole-table so a table recovered with one merged
/// column still scores most of its cells; whole-table matching would score zero
/// and hide the difference between "nearly right" and "entirely wrong".
///
/// **Defined, unmeasured** — same reason as `ReadingOrderTau`.
public enum TableStructureF1 {
    public struct Cell: Hashable, Sendable {
        public let row: Int
        public let column: Int
        public let text: String

        public init(row: Int, column: Int, text: String) {
            self.row = row
            self.column = column
            self.text = MetricText.normalize(text)
        }
    }

    /// Counts are stored; the ratios are computed and **optional**, because a
    /// ratio with a zero denominator is undefined, not zero. Reporting 0 recall
    /// against an empty reference would be a claim about an engine we never
    /// gave anything to find.
    public struct Result: Sendable, Equatable {
        public let truePositives: Int
        public let producedCount: Int
        public let referenceCount: Int

        public var precision: Double? {
            producedCount == 0 ? nil : Double(truePositives) / Double(producedCount)
        }
        public var recall: Double? {
            referenceCount == 0 ? nil : Double(truePositives) / Double(referenceCount)
        }
        public var f1: Double? {
            guard let precision, let recall, precision + recall > 0 else { return nil }
            return 2 * precision * recall / (precision + recall)
        }
    }

    public static func evaluate(produced: Set<Cell>, reference: Set<Cell>) -> Result {
        Result(truePositives: produced.intersection(reference).count,
               producedCount: produced.count,
               referenceCount: reference.count)
    }
}
