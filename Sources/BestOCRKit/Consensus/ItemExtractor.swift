import Foundation

/// One typed item extracted from a page, pre-normalization kept for output.
public struct ExtractedItem: Sendable {
    public let kind: ItemKind
    public let text: String
    public let normalized: String

    public init(kind: ItemKind, text: String, normalized: String) {
        self.kind = kind
        self.text = text
        self.normalized = normalized
    }
}

/// Page markdown → typed items (#11). Line-primary; markdown table rows are
/// split into per-cell items (the motivating failure class — table digits —
/// lives at cell granularity, per issue Clarity resolution).
public enum ItemExtractor {

    public static func extract(page: Int, text: String) -> [ExtractedItem] {
        var items: [ExtractedItem] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "---" else { continue }

            if isTableRow(line) {
                let cells = tableCells(line)
                if isSeparatorRow(cells) { continue }
                for cell in cells where !cell.isEmpty {
                    items.append(ExtractedItem(kind: .tableCell, text: cell,
                                               normalized: normalize(cell)))
                }
                continue
            }

            let kind: ItemKind = isMathLine(line) ? .math : .proseLine
            items.append(ExtractedItem(kind: kind, text: line, normalized: normalize(line)))
        }
        return items
    }

    /// Matching-only normalization: collapse whitespace runs (incl. full-width
    /// U+3000) to a single space and trim. Case and characters are preserved —
    /// case/char differences are real OCR signal, whitespace is not.
    public static func normalize(_ s: String) -> String {
        let unified = s.replacingOccurrences(of: "\u{3000}", with: " ")
        let parts = unified.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.joined(separator: " ")
    }

    // MARK: - Internals

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.count >= 2
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Leading/trailing "|" produce empty first/last fragments — drop them.
        if let first = cells.first, first.isEmpty { cells.removeFirst() }
        if let last = cells.last, last.isEmpty { cells.removeLast() }
        return cells
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func isMathLine(_ line: String) -> Bool {
        if line.hasPrefix("$$") || line.hasPrefix("\\[") { return true }
        return line.filter { $0 == "$" }.count >= 2
    }
}

/// Spine alignment (#11): the engine with the (upper-)median item count per
/// page becomes the spine — a degenerate engine (loop garbage collapsing to
/// one line) can never define the item universe. Other engines map onto the
/// spine by similarity-gated LCS; unmatched items survive as single-engine
/// items so the estimator can flag them lowConsensus, never silently dropped.
public enum ConsensusAlignment {

    static let similarityThreshold = 0.6

    public static func align(page: Int, extractions: [String: [ExtractedItem]]) -> [AlignedItem] {
        guard !extractions.isEmpty else { return [] }
        let engines = extractions.keys.sorted()

        // Spine = upper-median item count; ties broken by engine id.
        let byCount = engines.sorted {
            let (ca, cb) = (extractions[$0]!.count, extractions[$1]!.count)
            return ca != cb ? ca < cb : $0 < $1
        }
        let spineEngine = byCount[byCount.count / 2]
        let spine = extractions[spineEngine]!

        // responses[spineIndex] accumulates per-engine matches.
        var responses: [Int: [String: String]] = [:]
        for (i, item) in spine.enumerated() {
            responses[i] = [spineEngine: item.normalized]
        }
        var solo: [(engine: String, item: ExtractedItem)] = []

        for engine in engines where engine != spineEngine {
            let others = extractions[engine]!
            let matched = lcsMatch(spine: spine, other: others)
            var used = Set<Int>()
            for (si, oi) in matched {
                responses[si]?[engine] = others[oi].normalized
                used.insert(oi)
            }
            for (oi, item) in others.enumerated() where !used.contains(oi) {
                solo.append((engine, item))
            }
        }

        var out: [AlignedItem] = []
        for (i, item) in spine.enumerated() {
            out.append(AlignedItem(key: ItemKey(page: page, index: i, kind: item.kind),
                                   responses: responses[i] ?? [:]))
        }
        var nextIndex = spine.count
        for (engine, item) in solo.sorted(by: { $0.engine < $1.engine }) {
            out.append(AlignedItem(key: ItemKey(page: page, index: nextIndex, kind: item.kind),
                                   responses: [engine: item.normalized]))
            nextIndex += 1
        }
        return out
    }

    // MARK: - Internals

    /// LCS over (spine × other) with a similarity-gated match predicate.
    /// Returns monotone matched index pairs.
    private static func lcsMatch(spine: [ExtractedItem],
                                 other: [ExtractedItem]) -> [(Int, Int)] {
        let n = spine.count, m = other.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if matches(spine[i], other[j]) {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if matches(spine[i], other[j]) {
                pairs.append((i, j)); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    private static func matches(_ a: ExtractedItem, _ b: ExtractedItem) -> Bool {
        guard a.kind == b.kind else { return false }
        if a.normalized == b.normalized { return true }
        return similarity(a.normalized, b.normalized) >= similarityThreshold
    }

    /// 1 − normalizedLevenshtein. Exact DP — items are line/cell sized.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let ca = Array(a), cb = Array(b)
        if ca.isEmpty || cb.isEmpty { return 0 }
        var prev = Array(0...cb.count)
        var curr = Array(repeating: 0, count: cb.count + 1)
        for i in 1...ca.count {
            curr[0] = i
            for j in 1...cb.count {
                let cost = ca[i - 1] == cb[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        let dist = Double(prev[cb.count])
        return 1 - dist / Double(max(ca.count, cb.count))
    }
}
