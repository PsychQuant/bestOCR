import Foundation
import Testing
@testable import BestOCRKit

/// Spine alignment (#11): per-page item sequences from N engines → AlignedItems.
struct ConsensusAlignmentTests {

    private func page(_ engine: String, _ lines: [String]) -> (String, [ExtractedItem]) {
        (engine, lines.enumerated().map { idx, t in
            ExtractedItem(kind: .proseLine, text: t, normalized: ItemExtractor.normalize(t))
        })
    }

    @Test func identicalSequencesAlignOneToOne() {
        let lines = ["alpha beta", "gamma delta", "epsilon"]
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": page("A", lines).1,
            "B": page("B", lines).1,
        ])
        #expect(aligned.count == 3)
        #expect(aligned.allSatisfy { $0.responses.count == 2 })
        #expect(aligned[0].responses["A"]?.normalized == aligned[0].responses["B"]?.normalized)
    }

    @Test func nearMatchAlignsDespiteOneCharDifference() {
        // The motivating case: 形近字 — same line, one character differs.
        let a = ["申請文件如下", "第二行完全相同"]
        let b = ["甲請文件如下", "第二行完全相同"]
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": a.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
            "B": b.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
        ])
        #expect(aligned.count == 2, "near-identical lines must align, not fork")
        #expect(aligned[0].responses["A"]?.raw == "申請文件如下")
        #expect(aligned[0].responses["B"]?.raw == "甲請文件如下")
    }

    @Test func extraLineInOneEngineDoesNotDerail() {
        // Engine B hallucinated an extra line between two real ones.
        let a = ["one", "two"]
        let b = ["one", "SPURIOUS", "two"]
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": a.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
            "B": b.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
        ])
        // "one" and "two" each align across both engines; SPURIOUS becomes a
        // single-engine item (later flagged lowConsensus by the estimator).
        let both = aligned.filter { $0.responses.count == 2 }
        let solo = aligned.filter { $0.responses.count == 1 }
        #expect(both.count == 2)
        #expect(solo.count == 1)
        #expect(solo[0].responses["B"]?.raw == "SPURIOUS")
    }

    @Test func mathAndProseRenderingsOfSameLineAlign() {
        // Verify #11 finding 1: a VLM renders math as LaTeX (`$…$` → .math)
        // while Vision renders the same source line as plain text
        // (.proseLine). Kind is an engine-dependent rendering artifact, not
        // content identity — the two renderings must land on ONE item so the
        // estimator can adjudicate, not fork into two solo items.
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "paddle": ItemExtractor.extract(page: 1, text: "$E = mc^2$"),
            "vision": ItemExtractor.extract(page: 1, text: "E = mc^2"),
        ])
        #expect(aligned.count == 1, "one source line must yield one aligned item")
        #expect(aligned.first?.responses.count == 2)
    }

    @Test func crossKindSoloRenderingsMergeIntoOneItem() {
        // Same finding, solo-merge path: the spine (median count) lacks the
        // math line entirely; the two engines that saw it render it as .math
        // vs .proseLine. Their unmatched items must corroborate each other in
        // the cross-engine solo merge, not fragment into two singletons.
        let short = "l1\nl2"
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": ItemExtractor.extract(page: 1, text: short),
            "D": ItemExtractor.extract(page: 1, text: short),
            "E": ItemExtractor.extract(page: 1, text: short),
            "B": ItemExtractor.extract(page: 1, text: "l1\n$x + y$\nl2"),
            "C": ItemExtractor.extract(page: 1, text: "l1\nx + y\nl2"),
        ])
        #expect(aligned.count == 3, "l1, l2, and ONE merged math item")
        let solo = aligned.filter { $0.responses.keys.contains("B") && $0.responses.keys.contains("C")
            && $0.responses.count == 2 }
        #expect(solo.count == 1, "B's LaTeX and C's plain rendering must share one item")
    }

    @Test func canonicalLabelStripsOnlyPairedOuterDelimiters() {
        // The vote-label relation: paired OUTER math delimiters are a
        // rendering choice; interior/unpaired `$` is content (currency).
        #expect(ItemExtractor.canonicalLabel("$E = mc^2$") == "E = mc^2")
        #expect(ItemExtractor.canonicalLabel("$$x$$") == "x")
        #expect(ItemExtractor.canonicalLabel("$5 and $6") == "$5 and $6")
        #expect(ItemExtractor.canonicalLabel("$5") == "$5")
        #expect(ItemExtractor.canonicalLabel("plain") == "plain")
        // Mismatched delimiter widths never downgrade to the single-$ rule.
        #expect(ItemExtractor.canonicalLabel("$$$$") == "$$$$")
        #expect(ItemExtractor.canonicalLabel("$$x$") == "$$x$")
        #expect(ItemExtractor.canonicalLabel("$x$$") == "$x$$")
        // An escaped closing dollar is content, not a delimiter.
        #expect(ItemExtractor.canonicalLabel("$x\\$") == "$x\\$")
        // Normalization happens before delimiter detection → idempotent.
        #expect(ItemExtractor.canonicalLabel(" $x$ ") == "x")
        #expect(ItemExtractor.canonicalLabel(ItemExtractor.canonicalLabel(" $x$ "))
                == ItemExtractor.canonicalLabel(" $x$ "))
    }

    @Test func crossKindGapPairingNeedsContentEvidence() {
        // Round-2 finding: equal-gap pairing is positional-only; widening it
        // to math↔prose must not let an unrelated prose hallucination
        // substitute for a math line at the same position.
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": ItemExtractor.extract(page: 1, text: "head\n$x + y$\ntail"),
            "B": ItemExtractor.extract(page: 1, text: "head\nTOTAL DUE\ntail"),
        ])
        let singles = aligned.filter { $0.responses.count == 1 }
        #expect(singles.count == 2, "unrelated cross-kind lines at the same position must fork, not merge")

        // …while a garbled rendering of the SAME math must still pair.
        let garbled = ConsensusAlignment.align(page: 1, extractions: [
            "A": ItemExtractor.extract(page: 1, text: "head\n$x + y$\ntail"),
            "B": ItemExtractor.extract(page: 1, text: "head\nx + v\ntail"),
        ])
        #expect(garbled.count == 3, "garbled rendering of the same math must still land on one item")
    }

    @Test func mergedCrossKindGroupKindIsEngineOrderIndependent() {
        // Round-2 finding: the merged group's kind came from the first
        // exemplar (engine-name order) — renaming engines flipped the item
        // kind and with it the per-kind competence attribution. Math content
        // identity must win regardless of which engine is seen first.
        let short = "l1\nl2"
        func mergedKind(mathEngine: String, proseEngine: String) -> ItemKind? {
            let aligned = ConsensusAlignment.align(page: 1, extractions: [
                "A": ItemExtractor.extract(page: 1, text: short),
                "D": ItemExtractor.extract(page: 1, text: short),
                "E": ItemExtractor.extract(page: 1, text: short),
                mathEngine: ItemExtractor.extract(page: 1, text: "l1\n$x + y$\nl2"),
                proseEngine: ItemExtractor.extract(page: 1, text: "l1\nx + y\nl2"),
            ])
            return aligned.first { $0.responses.count == 2 }?.key.kind
        }
        #expect(mergedKind(mathEngine: "B", proseEngine: "C") == .math)
        #expect(mergedKind(mathEngine: "C", proseEngine: "B") == .math)
    }

    @Test func tableRowRespectsTheItemCap() {
        // #13 verify (Codex): the cap was checked per LINE — one wide table
        // row could blow past it. It must hold per ITEM.
        let prose = Array(repeating: "line", count: 1_999)
        let wideRow = "|" + Array(repeating: "c", count: 100).joined(separator: "|") + "|"
        let text = (prose + [wideRow]).joined(separator: "\n")
        #expect(ItemExtractor.extract(page: 1, text: text).count == 2_000)
    }

    @Test func mathEnvironmentsAreRestrictedToMathOnes() {
        // #13 verify (Codex): \begin{itemize}/\begin{document} are NOT math —
        // over-broad classification pollutes competence_by_kind.
        #expect(ItemExtractor.extract(page: 1, text: #"\begin{itemize}"#).first?.kind == .proseLine)
        #expect(ItemExtractor.extract(page: 1, text: #"\begin{align}"#).first?.kind == .math)
    }

    @Test func soloMergeNeedsTheSameGapInterval() {
        // #13 verify (Codex): prev-anchor alone cannot prove the same gap —
        // engines missing DIFFERENT middle spine items got merged. The
        // interval (prev, next) must match.
        let spine = "s0\ns1\ns2\ns3"
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": ItemExtractor.extract(page: 1, text: spine),
            "D": ItemExtractor.extract(page: 1, text: spine),
            "E": ItemExtractor.extract(page: 1, text: spine),
            // B: matches s0 only → its solo lives in interval (0, end).
            // (Unequal gap sizes keep equal-gap pairing out of the picture.)
            "B": ItemExtractor.extract(page: 1, text: "s0\nxx yy zz"),
            // C: matches s0, s1, s2 → its solo lives in interval (0, 1)
            "C": ItemExtractor.extract(page: 1, text: "s0\nxx yy zz\ns1\ns2"),
        ])
        let solos = aligned.filter { $0.responses.keys.contains("B") || $0.responses.keys.contains("C") }
            .filter { !$0.responses.keys.contains("A") }
        #expect(solos.count == 2, "different intervals must not merge (got \(solos.count))")
    }

    @Test func noMatchEngineGoesToTheTailNotTheTop() {
        // #13 verify (Codex): an engine with zero matches has NO positional
        // evidence — dumping its items before the spine is worse than the
        // old tail placement.
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": ItemExtractor.extract(page: 1, text: "l1\nl2"),
            "B": ItemExtractor.extract(page: 1, text: "l1\nl2"),
            "Z": ItemExtractor.extract(page: 1, text: "zzz1\nzzz2\nzzz3"),
        ])
        #expect(aligned.first?.responses.keys.contains("A") == true,
                "the spine opens the page; no-position items close it")
        #expect(aligned.last?.responses.keys.contains("Z") == true)
    }

    @Test func soloItemsInterleaveAtTheirGapPosition() {
        // #13 F6: an item the spine missed must come back at its gap
        // position, not get appended to the page tail — reading order is
        // part of the transcript contract.
        let short = "l1\nl2"
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": ItemExtractor.extract(page: 1, text: short),
            "D": ItemExtractor.extract(page: 1, text: short),
            "E": ItemExtractor.extract(page: 1, text: short),
            "B": ItemExtractor.extract(page: 1, text: "l1\n$x + y$\nl2"),
            "C": ItemExtractor.extract(page: 1, text: "l1\nx + y\nl2"),
        ])
        #expect(aligned.count == 3)
        #expect(aligned[0].responses["A"]?.raw == "l1")
        #expect(aligned[1].responses["B"]?.raw == "$x + y$",
                "the merged solo sits between its anchors, not at the tail")
        #expect(aligned[2].responses["A"]?.raw == "l2")
        #expect(aligned[1].key.index == 1 && aligned[2].key.index == 2,
                "indices follow reading order")
    }

    @Test func degenerateFlaggedEngineNeverDefinesTheSpine() {
        // #13 F4: a self-repetition loop has HIGH item count — upper-median
        // alone hands it the spine in the 2-engine case. The engine's own
        // degenerate flag must veto spine candidacy.
        let loop = Array(repeating: "loop garbage line", count: 40)
        let real = ["real one", "real two", "real three"]
        let extractions = [
            "A": real.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
            "C": loop.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
        ]
        #expect(ConsensusAlignment.spineEngine(engines: ["A", "C"], extractions: extractions,
                                               degenerate: ["C"]) == "A",
                "the degenerate flag must veto the high-count loop engine")
        #expect(ConsensusAlignment.spineEngine(engines: ["A", "C"], extractions: extractions,
                                               degenerate: []) == "C",
                "documents the N=2 limitation the veto exists for: without the flag, upper-median picks the loop")
    }

    @Test func separatorNeedsThreeDashesRealDataRowsSurvive() {
        // #13 F13: `| - | - |` is DATA; only `---`-style cells are separators.
        let kept = ItemExtractor.extract(page: 1, text: "| - | - |")
        #expect(kept.count == 2, "single-dash cells are data, not a separator row")
        let dropped = ItemExtractor.extract(page: 1, text: "| --- | :---: |")
        #expect(dropped.isEmpty, "canonical markdown separator row is dropped")
    }

    @Test func emptyTableCellsKeepTheirColumnPosition() {
        // #13 F13: `| A || C |` has three columns — dropping the empty one
        // shifts every later column and misaligns cells across engines.
        let cells = ItemExtractor.extract(page: 1, text: "| A || C |")
        #expect(cells.count == 3)
        #expect(cells[1].normalized.isEmpty)
    }

    @Test func mathHeuristicCoversParenAndEnvironmentForms() {
        // #13 F14: \( … \) and \begin{equation} are math renderings too.
        #expect(ItemExtractor.extract(page: 1, text: #"\(x + y\)"#).first?.kind == .math)
        #expect(ItemExtractor.extract(page: 1, text: #"\begin{equation}"#).first?.kind == .math)
    }

    @Test func extractionCapsBoundDegenerateInput() {
        // #13 F9: unbounded LCS×Levenshtein over loop garbage is a CPU/OOM
        // hazard — item count and line length are capped (documented).
        let hugeLine = String(repeating: "x", count: 10_000)
        let one = ItemExtractor.extract(page: 1, text: hugeLine)
        #expect((one.first?.normalized.count ?? 0) <= 4000)
        let manyLines = Array(repeating: "line", count: 2_500).joined(separator: "\n")
        let items = ItemExtractor.extract(page: 1, text: manyLines)
        #expect(items.count <= 2000)
    }

    @Test func spineIsMedianLineCountEngine() {
        // Degenerate engine (loop garbage → 1 line) must not become the spine.
        let a = ["l1", "l2", "l3"]
        let b = ["l1", "l2", "l3"]
        let c = ["garbage-only"]
        let aligned = ConsensusAlignment.align(page: 1, extractions: [
            "A": a.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
            "B": b.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
            "C": c.map { ExtractedItem(kind: .proseLine, text: $0, normalized: ItemExtractor.normalize($0)) },
        ])
        #expect(aligned.filter { $0.responses.count >= 2 }.count == 3,
                "3-line spine must survive the 1-line degenerate engine")
    }
}
