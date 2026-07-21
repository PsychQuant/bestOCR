/// Per-model quirks live here, not at call sites (spec §8): prompt contract,
/// default Ollama tag, output level. Roster mirrors evidence/candidates.json
/// admitted models (T2, 2026-07-20).
public struct ModelProfile: Sendable {
    public let id: String           // stable profile id → engine id "vlm.<id>"
    public let ollamaModel: String  // default Ollama tag; CLI --model overrides
    public let prompt: String
    public let outputLevel: OutputLevel
    /// Y3 delimiter caveat (candidates.json): the model emits \( \) math —
    /// VLMEngine rewrites matched pairs to $ / $$ so cross-engine output (and
    /// the instrument's $-density estimand) stays comparable.
    public let normalizesMathDelimiters: Bool

    public init(id: String, ollamaModel: String, prompt: String,
                outputLevel: OutputLevel, normalizesMathDelimiters: Bool = false) {
        self.id = id
        self.ollamaModel = ollamaModel
        self.prompt = prompt
        self.outputLevel = outputLevel
        self.normalizesMathDelimiters = normalizesMathDelimiters
    }

    /// The instrument's shared instruction prompt (measureOCR Prompt.ocr),
    /// duplicated verbatim so the product never imports the frozen instrument.
    public static let sharedInstructionPrompt =
        "Convert this document page to Markdown. Render all mathematical formulas as LaTeX (inline $...$, display $$...$$). Reproduce headings, lists and tables. Output only the transcription, no commentary."

    // Default tags are the SHA256-pinned -anova builds present on this
    // machine (verified live 2026-07-21), at nominal-8-bit per the
    // instrument's E2 convention. CLI --model overrides for other quants.
    public static let glmOCR = ModelProfile(
        id: "glm-ocr", ollamaModel: "glm-ocr-anova:q8_0",
        prompt: sharedInstructionPrompt, outputLevel: .mathMarkdown)

    public static let ovisOCR2 = ModelProfile(
        id: "ovisocr2", ollamaModel: "ovisocr2-anova:q8_0",
        prompt: sharedInstructionPrompt, outputLevel: .mathMarkdown)

    /// candidates.json caveat (2026-07-20): REQUIRES the native task prompt —
    /// generic instruction prompts yield degenerate loops. Math arrives as
    /// \( \) not $ → the Y3 delimiter-normalization flag rewrites it.
    public static let paddleOCRVL = ModelProfile(
        id: "paddleocr-vl", ollamaModel: "paddleocr-vl-anova:q8_0",
        prompt: "OCR:", outputLevel: .mathMarkdown,
        normalizesMathDelimiters: true)

    public static let all: [ModelProfile] = [glmOCR, ovisOCR2, paddleOCRVL]
}
