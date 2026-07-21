/// Degenerate-generation fuse (spec §8): flags VLM output that has collapsed
/// into a repetition loop (e.g. PaddleOCR-VL under a non-native prompt).
/// Mirrors the instrument's guard thresholds (measureOCR maxRunLength 200)
/// without depending on the frozen instrument.
public struct RepetitionGuard: Sendable {
    public let maxCharRun: Int
    public let maxTokenRepeat: Int

    public init(maxCharRun: Int = 200, maxTokenRepeat: Int = 50) {
        self.maxCharRun = maxCharRun
        self.maxTokenRepeat = maxTokenRepeat
    }

    public func flags(_ text: String) -> Bool {
        // Run of identical characters.
        var runChar: Character? = nil
        var runLength = 0
        for ch in text {
            if ch == runChar {
                runLength += 1
                if runLength >= maxCharRun { return true }
            } else {
                runChar = ch
                runLength = 1
            }
        }
        // Run of identical whitespace-separated tokens.
        var runToken: Substring? = nil
        var tokenCount = 0
        for token in text.split(whereSeparator: \.isWhitespace) {
            if token == runToken {
                tokenCount += 1
                if tokenCount >= maxTokenRepeat { return true }
            } else {
                runToken = token
                tokenCount = 1
            }
        }
        return false
    }
}
