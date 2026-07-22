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
        #expect(aligned[0].responses["A"] == aligned[0].responses["B"])
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
        #expect(aligned[0].responses["A"] == "申請文件如下")
        #expect(aligned[0].responses["B"] == "甲請文件如下")
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
        #expect(solo[0].responses["B"] == "SPURIOUS")
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
