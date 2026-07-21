import Testing
@testable import BestOCRKit

struct MathDelimiterNormalizerTests {
    @Test func inlinePairBecomesSingleDollar() {
        #expect(MathDelimiterNormalizer.normalize(#"Energy \(E = mc^2\) holds."#)
                == "Energy $E = mc^2$ holds.")
    }

    @Test func displayPairBecomesDoubleDollar() {
        #expect(MathDelimiterNormalizer.normalize(#"\[x + y = z\]"#) == "$$x + y = z$$")
    }

    @Test func displayPairSpansLines() {
        #expect(MathDelimiterNormalizer.normalize("\\[\na = b\n\\]") == "$$\na = b\n$$")
    }

    @Test func multiplePairsInOneText() {
        #expect(MathDelimiterNormalizer.normalize(#"\(a\) and \(b\), then \[c\]"#)
                == "$a$ and $b$, then $$c$$")
    }

    @Test func unmatchedOpenIsLeftAlone() {
        #expect(MathDelimiterNormalizer.normalize(#"broken \( tail"#) == #"broken \( tail"#)
    }

    @Test func unmatchedCloseIsLeftAlone() {
        #expect(MathDelimiterNormalizer.normalize(#"broken \) tail"#) == #"broken \) tail"#)
    }

    @Test func escapedBackslashIsNotADelimiter() {
        // "\\(" is a LaTeX row break followed by a plain paren, not an opener.
        #expect(MathDelimiterNormalizer.normalize(#"row \\( x"#) == #"row \\( x"#)
    }

    @Test func matrixRowBreaksInsideDisplayMathSurvive() {
        #expect(MathDelimiterNormalizer.normalize(#"\[a \\ b\]"#) == #"$$a \\ b$$"#)
    }

    @Test func contentEndingInRowBreakBeforeCloseSurvives() {
        // chars: \( a \\ \) — the \\ pair must not swallow the closer's backslash.
        #expect(MathDelimiterNormalizer.normalize(#"\(a\\\)"#) == #"$a\\$"#)
    }

    @Test func existingDollarMathIsUntouched() {
        #expect(MathDelimiterNormalizer.normalize("has $x$ and $$y$$ already")
                == "has $x$ and $$y$$ already")
    }

    @Test func emptyStringPassesThrough() {
        #expect(MathDelimiterNormalizer.normalize("") == "")
    }

    @Test func plainProseWithoutDelimitersPassesThrough() {
        let prose = "第一節 導論:無任何數學。"
        #expect(MathDelimiterNormalizer.normalize(prose) == prose)
    }
}
