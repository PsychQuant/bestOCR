import Foundation

/// The compare metric — a NAMED, VERSIONED formula (schema.md hard rule 2):
/// multiset token recall of a candidate transcription against a cloud
/// reference transcription. This is NOT `quality.word_recall` (whose referent
/// is pdftotext / ABBYY ground truth) and the two must never be conflated —
/// the cloud reference is itself a model output, not ground truth.
public enum Comparator {
    public static let formulaID = "quality.token_recall_vs_cloud@v1"

    /// Lowercase, NFC-precompose (so é stays one letter), then split on any
    /// non-alphanumeric run — punctuation (incl. em-dash, slashes) separates
    /// tokens instead of gluing them. Deterministic across platforms.
    public static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: { character in
                !character.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0)
                }
            })
            .map(String.init)
    }

    /// |multiset intersection| / |reference tokens|; empty reference → 0.
    public static func tokenRecall(candidate: String, reference: String) -> Double {
        let referenceTokens = normalize(reference)
        guard !referenceTokens.isEmpty else { return 0 }
        var counts: [String: Int] = [:]
        for token in referenceTokens { counts[token, default: 0] += 1 }
        var matched = 0
        for token in normalize(candidate) {
            if let remaining = counts[token], remaining > 0 {
                counts[token] = remaining - 1
                matched += 1
            }
        }
        return Double(matched) / Double(referenceTokens.count)
    }
}
