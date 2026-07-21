/// Y3 delimiter normalization (evidence/candidates.json caveat): PaddleOCR-VL
/// emits LaTeX `\( \)` / `\[ \]` math delimiters where every other admitted
/// model — and the instrument's $-density estimand (Y3) — uses `$` / `$$`.
/// Only MATCHED pairs convert; unmatched delimiters pass through untouched,
/// and an escaped backslash pair (`\\`, e.g. a matrix row break) is never
/// read as part of a delimiter.
public enum MathDelimiterNormalizer {
    public static func normalize(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let character = text[i]
            guard character == "\\" else {
                out.append(character)
                i = text.index(after: i)
                continue
            }
            let next = text.index(after: i)
            guard next < text.endIndex else {
                out.append(character)
                break
            }
            switch text[next] {
            case "\\":                       // escaped backslash — consume as a unit
                out += "\\\\"
                i = text.index(after: next)
            case "(", "[":
                let isInline = text[next] == "("
                let contentStart = text.index(after: next)
                if let close = findClose(in: text, from: contentStart,
                                         closer: isInline ? ")" : "]") {
                    let dollars = isInline ? "$" : "$$"
                    out += dollars
                    out += text[contentStart..<close]
                    out += dollars
                    i = text.index(close, offsetBy: 2)   // past the closing "\X"
                } else {                     // unmatched opener stays literal
                    out.append(character)
                    out.append(text[next])
                    i = text.index(after: next)
                }
            default:
                out.append(character)
                i = next
            }
        }
        return out
    }

    /// Index of the `\` of the first unescaped `\<closer>` at or after `from`,
    /// scanning with the same `\\`-consumption rule as the main pass.
    private static func findClose(in text: String, from: String.Index,
                                  closer: Character) -> String.Index? {
        var i = from
        while i < text.endIndex {
            guard text[i] == "\\" else {
                i = text.index(after: i)
                continue
            }
            let next = text.index(after: i)
            guard next < text.endIndex else { return nil }
            if text[next] == "\\" {
                i = text.index(after: next)
            } else if text[next] == closer {
                return i
            } else {
                i = next
            }
        }
        return nil
    }
}
