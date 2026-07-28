import Foundation
import Testing
@testable import BestOCRKit

/// Phase 2 of the document-assembly spec: the two assembly estimands exist as
/// *formulas*, tested against hand-computed cases. They stay **unmeasured**
/// (no annotated reference subset, §6.3) — but a formula that only exists in
/// prose cannot be checked, and schema hard rule 2 forbids naming an estimand
/// without one.
struct StructureMetricsTests {
    static func blocks(_ texts: [String]) -> [DocumentBlock] {
        texts.map { DocumentBlock(page: 1, kind: .paragraph, text: $0) }
    }

    // MARK: - quality.reading_order_tau@v1

    @Test func identicalOrderScoresOne() {
        let reference = Self.blocks(["header", "q1", "q2", "q3"])
        let result = ReadingOrderTau.evaluate(produced: reference, reference: reference)
        #expect(result.matched == 4)
        #expect(result.tau == 1.0)
    }

    /// n = 4 fully reversed: all 6 pairs discordant → tau = −1.
    @Test func fullReversalScoresMinusOne() {
        let reference = Self.blocks(["a", "b", "c", "d"])
        let result = ReadingOrderTau.evaluate(
            produced: Self.blocks(["d", "c", "b", "a"]), reference: reference)
        #expect(result.tau == -1.0)
    }

    /// marker's actual failure: one header displaced by one position.
    /// produced ref-indices [1,0,2,3] → C = 5, D = 1, tau = 4/6.
    @Test func oneDisplacedBlockScoresHandComputedTau() throws {
        let reference = Self.blocks(["header", "q1", "q2", "q3"])
        let result = ReadingOrderTau.evaluate(
            produced: Self.blocks(["q1", "header", "q2", "q3"]), reference: reference)
        #expect(result.matched == 4)
        let tau = try #require(result.tau)
        #expect(abs(tau - 4.0 / 6.0) < 1e-12)
    }

    /// A block travelling further must be penalised more — this is the whole
    /// reason tau-b was chosen over "count of misplaced blocks".
    @Test func fartherDisplacementIsPenalisedMore() {
        let reference = Self.blocks(["h", "a", "b", "c", "d"])
        let nearby = ReadingOrderTau.evaluate(
            produced: Self.blocks(["a", "h", "b", "c", "d"]), reference: reference)
        let distant = ReadingOrderTau.evaluate(
            produced: Self.blocks(["a", "b", "c", "d", "h"]), reference: reference)
        #expect((nearby.tau ?? 0) > (distant.tau ?? 0))
    }

    /// Unmatched blocks are a DETECTION failure and must not enter an ORDERING
    /// coefficient (schema hard rule 2 — two estimands, never blended).
    @Test func unmatchedBlocksAreReportedSeparatelyNotFoldedIn() {
        let reference = Self.blocks(["a", "b", "c"])
        let result = ReadingOrderTau.evaluate(
            produced: Self.blocks(["a", "b", "totally different invented text"]),
            reference: reference)
        #expect(result.matched == 2)
        #expect(result.unmatchedProduced == 1)
        #expect(result.unmatchedReference == 1)
        // The two blocks that DID match are in the right order.
        #expect(result.tau == 1.0)
    }

    /// OCR noise inside a block must not break the match.
    @Test func matchingToleratesMinorTextDifferences() {
        let result = ReadingOrderTau.evaluate(
            produced: Self.blocks(["Question  one.", "questlon two"]),
            reference: Self.blocks(["Question one.", "question two"]))
        #expect(result.matched == 2)
        #expect(result.unmatchedProduced == 0)
    }

    /// Fewer than two matched pairs has no correlation — report nil, never 0
    /// (0 would read as "uncorrelated", which is a claim).
    @Test func tauIsNilWhenThereIsNothingToCorrelate() {
        let single = ReadingOrderTau.evaluate(produced: Self.blocks(["a"]),
                                             reference: Self.blocks(["a"]))
        #expect(single.tau == nil)
        #expect(single.matched == 1)
        let empty = ReadingOrderTau.evaluate(produced: [], reference: [])
        #expect(empty.tau == nil)
    }

    // MARK: - quality.table_structure_f1@v1

    static func cells(_ triples: [(Int, Int, String)]) -> Set<TableStructureF1.Cell> {
        Set(triples.map { TableStructureF1.Cell(row: $0.0, column: $0.1, text: $0.2) })
    }

    @Test func perfectTableScoresOne() {
        let reference = Self.cells([(0, 0, "a"), (0, 1, "b"), (1, 0, "c"), (1, 1, "d")])
        let result = TableStructureF1.evaluate(produced: reference, reference: reference)
        #expect(result.f1 == 1.0)
        #expect(result.precision == 1.0)
        #expect(result.recall == 1.0)
    }

    /// The paddle pipeline's known quirk: a multiple-choice block emitted as a
    /// spurious table. Precision MUST drop; recall MUST be untouched — that is
    /// the right description of the failure, and why cell-level F1 was chosen.
    @Test func spuriousTableDropsPrecisionAndLeavesRecallIntact() throws {
        let reference = Self.cells([(0, 0, "a"), (0, 1, "b"), (1, 0, "c"), (1, 1, "d")])
        var produced = reference
        for row in 0..<6 { produced.insert(TableStructureF1.Cell(row: row, column: 9,
                                                                text: "choice \(row)")) }
        let result = TableStructureF1.evaluate(produced: produced, reference: reference)
        #expect(result.recall == 1.0)
        let precision = try #require(result.precision)
        #expect(abs(precision - 4.0 / 10.0) < 1e-12)
        let f1 = try #require(result.f1)
        #expect(abs(f1 - 2 * 0.4 * 1.0 / 1.4) < 1e-12)
    }

    /// A merged column loses some cells and keeps the rest — graceful
    /// degradation is the reason this is not whole-table matching.
    @Test func mergedColumnDegradesGracefullyInsteadOfScoringZero() throws {
        let reference = Self.cells([(0, 0, "a"), (0, 1, "b"), (1, 0, "c"), (1, 1, "d")])
        let produced = Self.cells([(0, 0, "a"), (0, 1, "b c"), (1, 0, "c"), (1, 1, "d")])
        let f1 = try #require(TableStructureF1.evaluate(produced: produced,
                                                        reference: reference).f1)
        #expect(f1 > 0.0 && f1 < 1.0)
    }

    @Test func cellTextIsComparedNormalized() {
        let reference = Self.cells([(0, 0, "Total  Score")])
        let produced = Self.cells([(0, 0, "total score")])
        #expect(TableStructureF1.evaluate(produced: produced, reference: reference).f1 == 1.0)
    }

    /// No reference cells → recall is undefined. Reporting 0 would be a claim
    /// about an engine we never gave anything to find.
    @Test func undefinedRatiosAreNilNotZero() {
        let spuriousOnly = TableStructureF1.evaluate(
            produced: Self.cells([(0, 0, "x")]), reference: [])
        #expect(spuriousOnly.precision == 0.0)
        #expect(spuriousOnly.recall == nil)
        #expect(spuriousOnly.f1 == nil)
        let nothingAtAll = TableStructureF1.evaluate(produced: [], reference: [])
        #expect(nothingAtAll.precision == nil)
        #expect(nothingAtAll.recall == nil)
    }
}
