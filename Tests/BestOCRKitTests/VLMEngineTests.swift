import Foundation
import Testing
@testable import BestOCRKit

struct VLMEngineTests {
    @Test func profileRosterCoversAdmittedCandidates() {
        let ids = ModelProfile.all.map(\.id)
        #expect(ids == ["glm-ocr", "ovisocr2", "paddleocr-vl"])
    }

    @Test func paddleUsesNativeTaskPrompt() {
        // candidates.json caveat: generic instruction prompts yield degenerate
        // loops — the native task prompt is mandatory for PaddleOCR-VL.
        #expect(ModelProfile.paddleOCRVL.prompt == "OCR:")
    }

    @Test func glmAndOvisUseSharedInstructionPrompt() {
        #expect(ModelProfile.glmOCR.prompt == ModelProfile.sharedInstructionPrompt)
        #expect(ModelProfile.ovisOCR2.prompt == ModelProfile.sharedInstructionPrompt)
        #expect(ModelProfile.sharedInstructionPrompt.contains("Markdown"))
    }

    @Test func engineIdentityAndCapabilities() {
        let engine = VLMEngine(profile: .glmOCR)
        #expect(engine.id == "vlm.glm-ocr")
        #expect(engine.family == .localVLM)
        #expect(engine.capabilities.outputLevel == .mathMarkdown)
        #expect(engine.capabilities.needsNetwork == false)   // localhost server, not internet
    }

    @Test func modelOverrideReplacesTag() {
        let engine = VLMEngine(profile: .glmOCR, modelOverride: "glm-ocr-anova:q4_K_M")
        #expect(engine.resolvedModelTag == "glm-ocr-anova:q4_K_M")
        let defaulted = VLMEngine(profile: .glmOCR)
        #expect(defaulted.resolvedModelTag == "glm-ocr-anova:q8_0")
    }

    @Test func probeAgainstDeadPortReportsServerDown() async {
        let engine = VLMEngine(profile: .glmOCR, host: "localhost:59999")
        let availability = await engine.probe()
        guard case .unavailable(let reason, let hint) = availability else {
            Issue.record("expected unavailable, got \(availability)")
            return
        }
        #expect(reason.contains("Ollama"))
        #expect(hint == "ollama serve")
    }
}
