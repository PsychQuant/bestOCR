import Testing
@testable import BestOCRKit

struct ComparatorTests {
    @Test func perfectAndPartialRecall() {
        #expect(Comparator.tokenRecall(candidate: "Hello, World!", reference: "hello world") == 1.0)
        #expect(Comparator.tokenRecall(candidate: "hello", reference: "hello world") == 0.5)
        #expect(Comparator.tokenRecall(candidate: "", reference: "hello") == 0.0)
        #expect(Comparator.tokenRecall(candidate: "x", reference: "") == 0.0)
    }

    @Test func multisetCountsDuplicates() {
        // reference has "a" twice; candidate supplies it once → 2 of 3 matched (one a + b)
        #expect(Comparator.tokenRecall(candidate: "a b", reference: "a a b") == 2.0 / 3.0)
    }

    @Test func normalizationStripsPunctuationAndCase() {
        #expect(Comparator.normalize("Héllo, WORLD—42!") == ["héllo", "world", "42"])
    }

    @Test func formulaIsNamedAndVersioned() {
        #expect(Comparator.formulaID == "quality.token_recall_vs_cloud@v1")
    }
}
