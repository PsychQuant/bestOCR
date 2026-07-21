/// Per-model quirks live here, not at call sites (spec §8): prompt contract,
/// default Ollama tag, output level. Roster mirrors evidence/candidates.json
/// admitted models (T2, 2026-07-20).
public struct ModelProfile: Sendable {
    public let id: String           // stable profile id → engine id "vlm.<id>"
    public let ollamaModel: String  // default Ollama tag; CLI --model overrides
    public let prompt: String
    public let outputLevel: OutputLevel

    /// The instrument's shared instruction prompt (measureOCR Prompt.ocr),
    /// duplicated verbatim so the product never imports the frozen instrument.
    public static let sharedInstructionPrompt =
        "Convert this document page to Markdown. Render all mathematical formulas as LaTeX (inline $...$, display $$...$$). Reproduce headings, lists and tables. Output only the transcription, no commentary."

    public static let glmOCR = ModelProfile(
        id: "glm-ocr", ollamaModel: "glm-ocr",
        prompt: sharedInstructionPrompt, outputLevel: .mathMarkdown)

    public static let ovisOCR2 = ModelProfile(
        id: "ovisocr2", ollamaModel: "ovisocr2",
        prompt: sharedInstructionPrompt, outputLevel: .mathMarkdown)

    /// candidates.json caveat (2026-07-20): REQUIRES the native task prompt —
    /// generic instruction prompts yield degenerate loops. Math arrives as
    /// \( \) not $ (delimiter normalization is deferred to M2 output work).
    public static let paddleOCRVL = ModelProfile(
        id: "paddleocr-vl", ollamaModel: "paddleocr-vl",
        prompt: "OCR:", outputLevel: .mathMarkdown)

    public static let all: [ModelProfile] = [glmOCR, ovisOCR2, paddleOCRVL]
}
