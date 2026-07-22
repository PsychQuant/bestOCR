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
