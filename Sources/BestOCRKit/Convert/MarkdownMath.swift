import Foundation

/// Does this markdown contain math a converter must preserve?
///
/// The answer picks the converter (#3: math → pandoc for native OMath, else
/// macdoc with literal LaTeX), so both error directions cost something real: a
/// false negative ships equations as literal `$…$` text, a false positive sends
/// a price list through a math-aware path.
///
/// The rule implemented here is **pandoc's own** (`tex_math_dollars`): an
/// opening `$` has a non-space immediately to its right; a closing `$` has a
/// non-space immediately to its left and is not immediately followed by a digit.
/// That single rule is what makes `$5 and $10` currency rather than an equation.
public enum MarkdownMath {
    public static func containsMath(_ markdown: String) -> Bool {
        var inFence = false
        var displayDelimiters = 0
        var candidateLines: [String] = []

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            // Fenced code is where `$HOME/$USER` lives, and it satisfies the
            // inline-math rule perfectly — excluding it is doing real work.
            if inFence { continue }
            let stripped = strippingInlineCode(line)
            displayDelimiters += countDisplayDelimiters(stripped)
            candidateLines.append(stripped)
        }
        // Display math is usually `$$` on its own line, so it is counted across
        // the document rather than per line.
        if displayDelimiters >= 2 { return true }
        return candidateLines.contains(where: hasInlineMath)
    }

    /// Drops `` `code` `` spans (any backtick-run length, closed by an equal run).
    static func strippingInlineCode(_ line: String) -> String {
        let chars = Array(line)
        var out = ""
        var index = 0
        while index < chars.count {
            guard chars[index] == "`" else {
                out.append(chars[index])
                index += 1
                continue
            }
            var runLength = 0
            while index + runLength < chars.count, chars[index + runLength] == "`" { runLength += 1 }
            var scan = index + runLength
            var closed = false
            while scan < chars.count {
                if chars[scan] == "`" {
                    var closeRun = 0
                    while scan + closeRun < chars.count, chars[scan + closeRun] == "`" { closeRun += 1 }
                    if closeRun == runLength {
                        index = scan + closeRun
                        closed = true
                        break
                    }
                    scan += closeRun
                    continue
                }
                scan += 1
            }
            if !closed {
                // Unclosed run is literal text, not a code span.
                out.append(String(repeating: "`", count: runLength))
                index += runLength
            }
        }
        return out
    }

    static func countDisplayDelimiters(_ line: String) -> Int {
        let chars = Array(line)
        var count = 0
        var index = 0
        while index < chars.count {
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "$", index + 1 < chars.count, chars[index + 1] == "$" {
                count += 1
                index += 2
                continue
            }
            index += 1
        }
        return count
    }

    static func hasInlineMath(_ line: String) -> Bool {
        let chars = Array(line)
        var open = 0
        while open < chars.count {
            if chars[open] == "\\" { open += 2; continue }          // \$ is a literal dollar
            guard chars[open] == "$" else { open += 1; continue }
            if open + 1 < chars.count, chars[open + 1] == "$" { open += 2; continue }
            guard open + 1 < chars.count, !chars[open + 1].isWhitespace else {
                open += 1
                continue
            }
            var close = open + 1
            while close < chars.count {
                if chars[close] == "\\" { close += 2; continue }
                if chars[close] == "$" {
                    let precededByText = !chars[close - 1].isWhitespace
                    let followedByDigit = close + 1 < chars.count && chars[close + 1].isNumber
                    if precededByText && !followedByDigit && close > open + 1 { return true }
                }
                close += 1
            }
            open += 1
        }
        return false
    }
}
