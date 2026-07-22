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
            // Resource caps (#13 F9): alignment is LCS×Levenshtein — loop
            // garbage (thousands of lines, multi-KB lines) must be bounded.
            // Truncation, not silence: the caps are named constants and
            // documented in the skill's honest limits.
            if items.count >= ConsensusAlignment.maxItemsPerPage { break }
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.count > ConsensusAlignment.maxLineLength {
                line = String(line.prefix(ConsensusAlignment.maxLineLength))
            }
            guard !line.isEmpty, line != "---" else { continue }

            if isTableRow(line) {
                let cells = tableCells(line)
                if isSeparatorRow(cells) { continue }
                // Empty cells stay as placeholder items (#13 F13): dropping
                // them shifts every later column and misaligns cells across
                // engines. An empty cell is a positional fact.
                for cell in cells {
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

    /// Markdown separator cells are `---` (≥3 dashes, optional `:` ends);
    /// a lone `-` or `:` is DATA (#13 F13) — dropping it loses a real row.
    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return body.count >= 3 && body.allSatisfy { $0 == "-" }
        }
    }

    private static func isMathLine(_ line: String) -> Bool {
        if line.hasPrefix("$$") || line.hasPrefix("\\[")
            || line.hasPrefix("\\(") || line.hasPrefix("\\begin{") { return true }
        return line.filter { $0 == "$" }.count >= 2
    }

    /// Canonical vote/match label: strips PAIRED OUTER math delimiters only —
    /// `$…$` / `$$…$$` are rendering choices, interior or unpaired `$` is
    /// content (currency), an escaped closing `\$` is content too. Mismatched
    /// delimiter widths (`$$…$`, `$…$$`, `$$$$`) never downgrade to the
    /// single-`$` rule. Normalizes FIRST so the function is idempotent and
    /// never strips down to empty. Voting, supporter counting, and
    /// cross-rendering matching all use this relation; stored responses keep
    /// the engine's raw rendering.
    static func canonicalLabel(_ s: String) -> String {
        let n = normalize(s)
        var t = n
        if t.hasPrefix("$$"), t.hasSuffix("$$"), t.count >= 5 {
            t = String(t.dropFirst(2).dropLast(2))
        } else if t.hasPrefix("$$") || t.hasSuffix("$$") {
            return n
        } else if t.hasPrefix("$"), t.hasSuffix("$"), t.count >= 3,
                  !String(t.dropLast()).hasSuffix("\\") {
            t = String(t.dropFirst().dropLast())
        }
        let out = normalize(t)
        return out.isEmpty ? n : out
    }
}

/// Spine alignment (#11): the engine with the (upper-)median item count per
/// page becomes the spine — a degenerate engine (loop garbage collapsing to
/// one line) can never define the item universe. Other engines map onto the
/// spine by similarity-gated LCS; unmatched items survive as single-engine
/// items so the estimator can flag them lowConsensus, never silently dropped.
public enum ConsensusAlignment {

    static let similarityThreshold = 0.6
    /// Content-evidence floor for CROSS-kind equal-gap pairs (same-kind pairs
    /// keep position-only trust so garbled lines still land together).
    static let crossKindGapSimilarityFloor = 0.3
    /// Resource caps (#13 F9): LCS×Levenshtein over degenerate OCR output is
    /// a CPU/OOM hazard. Documented in the skill's honest limits.
    static let maxItemsPerPage = 2000
    static let maxLineLength = 4000

    public static func align(page: Int, extractions: [String: [ExtractedItem]],
                             degenerate: Set<String> = []) -> [AlignedItem] {
        guard !extractions.isEmpty else { return [] }
        let engines = extractions.keys.sorted()

        // Spine = engine whose item count equals the (upper-)median count;
        // among those, the lexicographically smallest id (deterministic and
        // independent of who happens to sit at the median index).
        // Degenerate-flagged engines are vetoed from spine candidacy first
        // (#13 F4): a self-repetition loop has HIGH count, so upper-median
        // alone would hand it the spine in the 2-engine case — the engine's
        // own flag is the content signal count cannot provide. If every
        // engine is flagged, fall back to the full pool.
        let vetoed = engines.filter { !degenerate.contains($0) }
        let pool = vetoed.isEmpty ? engines : vetoed
        let counts = pool.map { extractions[$0]!.count }.sorted()
        let medianCount = counts[counts.count / 2]
        let spineEngine = pool.filter { extractions[$0]!.count == medianCount }.min()!
        let spine = extractions[spineEngine]!

        // responses[spineIndex] accumulates per-engine matches.
        var responses: [Int: [String: String]] = [:]
        for (i, item) in spine.enumerated() {
            responses[i] = [spineEngine: item.normalized]
        }
        var solo: [(engine: String, item: ExtractedItem)] = []

        for engine in engines where engine != spineEngine {
            let others = extractions[engine]!
            var matched = lcsMatch(spine: spine, other: others)
            matched.append(contentsOf: equalGapPairs(anchors: matched,
                                                     spine: spine, other: others))
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

        // Cross-merge solo items: unmatched items from DIFFERENT engines that
        // are the same content must corroborate each other, not fragment into
        // per-engine singletons. Greedy grouping by compatible kind +
        // similarity (math compared via canonicalLabel); one engine
        // contributes at most once per group. Group kind is content-based:
        // .math wins if ANY member saw math syntax — independent of engine
        // naming/order (a rendering artifact must not decide attribution).
        var groups: [(kind: ItemKind, exemplar: ExtractedItem, responses: [String: String])] = []
        for (engine, item) in solo.sorted(by: { $0.engine < $1.engine }) {
            var placed = false
            for g in groups.indices where kindCompatible(groups[g].kind, item.kind)
                && groups[g].responses[engine] == nil {
                let te = matchText(groups[g].exemplar), ti = matchText(item)
                if te == ti || similarity(te, ti) >= similarityThreshold {
                    groups[g].responses[engine] = item.normalized
                    if item.kind == .math { groups[g].kind = .math }
                    placed = true
                    break
                }
            }
            if !placed {
                groups.append((item.kind, item, [engine: item.normalized]))
            }
        }
        var nextIndex = spine.count
        for group in groups {
            out.append(AlignedItem(key: ItemKey(page: page, index: nextIndex, kind: group.kind),
                                   responses: group.responses))
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

    /// Positional pairing for equal-size gaps between LCS anchors — the
    /// changed-block heuristic from diff tools. When exactly k items on both
    /// sides sit between two consecutive anchors (or a boundary), position
    /// alone is strong evidence of correspondence; a heavily-garbled line
    /// then lands on the same item as its peers instead of forking off as a
    /// solo (so the majority can outvote it). Unequal gaps stay unpaired —
    /// the positional claim is weak there. Compatible-kind required per pair.
    private static func equalGapPairs(anchors: [(Int, Int)],
                                      spine: [ExtractedItem],
                                      other: [ExtractedItem]) -> [(Int, Int)] {
        var extra: [(Int, Int)] = []
        var prevS = -1, prevO = -1
        let boundaries = anchors + [(spine.count, other.count)]
        for (s, o) in boundaries {
            let gapS = s - prevS - 1
            let gapO = o - prevO - 1
            if gapS > 0, gapS == gapO {
                for t in 0..<gapS {
                    let si = prevS + 1 + t, oi = prevO + 1 + t
                    let sk = spine[si].kind, ok = other[oi].kind
                    if sk == ok {
                        extra.append((si, oi))
                    } else if kindCompatible(sk, ok),
                              similarity(matchText(spine[si]), matchText(other[oi]))
                                  >= crossKindGapSimilarityFloor {
                        // Cross-kind positional pairing is a NEW surface —
                        // demand weak content evidence so a prose
                        // hallucination cannot substitute for a math line.
                        extra.append((si, oi))
                    }
                }
            }
            prevS = s; prevO = o
        }
        return extra
    }

    /// Kind is an engine-dependent *rendering* of the same source line — a
    /// VLM emits `$…$` (.math) where Vision emits plain text (.proseLine).
    /// Treating kind as content identity fragments every math line into
    /// per-engine solo items that can never be adjudicated (verify #11
    /// finding 1). Math and prose renderings are alignable; table cells stay
    /// structural (pipe syntax, not a rendering choice).
    static func kindCompatible(_ a: ItemKind, _ b: ItemKind) -> Bool {
        if a == b { return true }
        return Set([a, b]) == Set([ItemKind.math, .proseLine])
    }

    /// Comparison key: math renderings drop their paired outer delimiters so
    /// `$E = mc^2$` and `E = mc^2` compare equal. Stored responses keep the
    /// engine's actual rendering — this is matching-only.
    private static func matchText(_ item: ExtractedItem) -> String {
        guard item.kind == .math else { return item.normalized }
        return ItemExtractor.canonicalLabel(item.normalized)
    }

    private static func matches(_ a: ExtractedItem, _ b: ExtractedItem) -> Bool {
        guard kindCompatible(a.kind, b.kind) else { return false }
        let ta = matchText(a), tb = matchText(b)
        if ta == tb { return true }
        return similarity(ta, tb) >= similarityThreshold
    }

    /// 1 − normalizedLevenshtein. Exact DP — items are line/cell sized.
    /// Length-ratio fast reject (#13 F9): true similarity is bounded above
    /// by min/max length, so a ratio below the lowest threshold in use
    /// (crossKindGapSimilarityFloor) can return 0 without running the DP —
    /// exact w.r.t. every caller's threshold comparison.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let ca = Array(a), cb = Array(b)
        if ca.isEmpty || cb.isEmpty { return 0 }
        let ratio = Double(min(ca.count, cb.count)) / Double(max(ca.count, cb.count))
        if ratio < crossKindGapSimilarityFloor { return 0 }
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
