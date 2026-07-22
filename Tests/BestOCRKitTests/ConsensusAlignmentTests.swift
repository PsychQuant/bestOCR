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
