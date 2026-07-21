import Foundation
import Testing
@testable import BestOCRKit

struct CloudReferenceEngineTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47])

    @Test func identitiesAndFamilies() {
        for provider in CloudProvider.allCases {
            let engine = CloudReferenceEngine(provider: provider)
            #expect(engine.id == provider.id)
            #expect(engine.family == .cloudReference)
            #expect(engine.capabilities.needsNetwork)
        }
        #expect(CloudProvider.allCases.map(\.id) == ["cloud.claude", "cloud.openai", "cloud.gemini"])
    }

    @Test func claudeRequestShape() throws {
        let request = CloudProvider.claude.makeRequest(
            imageData: png, mediaType: "image/png", prompt: "OCR this", key: "sk-test")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-4-8")   // skill-mandated default
        let content = try #require(((json["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.first?["type"] as? String == "image")    // image before text
        #expect(content.last?["type"] as? String == "text")
    }

    @Test func claudeParserReadsTextAndRejectsRefusal() throws {
        let ok = #"{"content":[{"type":"text","text":"HELLO"}],"stop_reason":"end_turn"}"#
        #expect(try CloudProvider.claude.parseText(from: Data(ok.utf8)) == "HELLO")
        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        #expect(throws: OCREngineError.self) {
            _ = try CloudProvider.claude.parseText(from: Data(refusal.utf8))
        }
    }

    @Test func openAIAndGeminiParsers() throws {
        let openai = #"{"choices":[{"message":{"content":"WORLD"}}]}"#
        #expect(try CloudProvider.openai.parseText(from: Data(openai.utf8)) == "WORLD")
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"A"},{"text":"B"}]}}]}"#
        #expect(try CloudProvider.gemini.parseText(from: Data(gemini.utf8)) == "AB")
    }

    @Test func probeReflectsKeyEnv() async {
        unsetenv("ANTHROPIC_API_KEY")
        let engine = CloudReferenceEngine(provider: .claude)
        guard case .unavailable(let reason, let hint) = await engine.probe() else {
            Issue.record("expected unavailable without key")
            return
        }
        #expect(reason.contains("ANTHROPIC_API_KEY"))
        #expect(hint?.contains("export ANTHROPIC_API_KEY") == true)
        setenv("ANTHROPIC_API_KEY", "sk-test", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        #expect(await engine.probe() == .available)
    }

    @Test func modelEnvOverride() {
        setenv("BESTOCR_CLAUDE_MODEL", "claude-haiku-4-5", 1)
        defer { unsetenv("BESTOCR_CLAUDE_MODEL") }
        #expect(CloudProvider.claude.resolvedModel == "claude-haiku-4-5")
    }
}
