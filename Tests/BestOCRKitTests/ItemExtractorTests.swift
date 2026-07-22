import Foundation
import Testing
@testable import BestOCRKit

/// ItemExtractor (#11): page markdown → typed, normalized items.
struct ItemExtractorTests {

    @Test func splitsProseLinesAndClassifiesMath() {
        let text = """
        First prose line.

        $E = mc^2$
        """
        let items = ItemExtractor.extract(page: 1, text: text)
        #expect(items.count == 2)
        #expect(items[0].kind == .proseLine)
        #expect(items[0].text == "First prose line.")
        #expect(items[1].kind == .math)
    }

    @Test func tableRowsSplitIntoCells() {
        let text = """
        | Col A | Col B |
        |---|---|
        | 0.039 | 0.024 |
        """
        let items = ItemExtractor.extract(page: 1, text: text)
        // Header row → 2 cells; separator row dropped; data row → 2 cells.
        let cells = items.filter { $0.kind == .tableCell }
        #expect(cells.count == 4)
        #expect(cells.map(\.text).contains("0.039"))
        #expect(items.allSatisfy { $0.kind == .tableCell })
    }

    @Test func normalizationCollapsesWhitespaceForMatchingOnly() {
        let a = ItemExtractor.normalize("The  quick   brown fox")
        let b = ItemExtractor.normalize("The quick brown fox")
        #expect(a == b, "whitespace runs must not distinguish responses")
        let c = ItemExtractor.normalize("全形　空白")
        #expect(c == ItemExtractor.normalize("全形 空白"))
    }

    @Test func emptyAndSeparatorLinesProduceNoItems() {
        let items = ItemExtractor.extract(page: 3, text: "\n\n---\n   \n")
        #expect(items.isEmpty)
    }
}
