import Foundation

/// Cloud vision providers for the reference tier (spec §5.4). Request/response
/// shapes are pure functions so they unit-test against canned JSON — no
/// network in tests. Defaults are data: model ids override via env.
public enum CloudProvider: String, CaseIterable, Sendable {
    case claude, openai, gemini

    public var id: String { "cloud.\(rawValue)" }

    public var keyEnv: String {
        switch self {
        case .claude: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        }
    }

    var modelEnv: String {
        switch self {
        case .claude: return "BESTOCR_CLAUDE_MODEL"
        case .openai: return "BESTOCR_OPENAI_MODEL"
        case .gemini: return "BESTOCR_GEMINI_MODEL"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-4-8"   // claude-api skill default mandate
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.5-flash"
        }
    }

    public var resolvedModel: String {
        ProcessInfo.processInfo.environment[modelEnv] ?? defaultModel
    }

    /// Build the provider-specific vision request. `key` is never logged.
    public func makeRequest(imageData: Data, mediaType: String, prompt: String,
                            key: String) -> URLRequest {
        let base64 = imageData.base64EncodedString()
        let body: [String: Any]
        var request: URLRequest
        switch self {
        case .claude:
            // Per claude-api skill cURL reference: image block before text.
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": resolvedModel,
                "max_tokens": 16000,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "image",
                         "source": ["type": "base64", "media_type": mediaType, "data": base64]],
                        ["type": "text", "text": prompt],
                    ],
                ]],
            ]
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": resolvedModel,
                "max_tokens": 4096,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url",
                         "image_url": ["url": "data:\(mediaType);base64,\(base64)"]],
                    ],
                ]],
            ]
        case .gemini:
            request = URLRequest(url: URL(string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(resolvedModel):generateContent")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "contents": [[
                    "parts": [
                        ["text": prompt],
                        ["inline_data": ["mime_type": mediaType, "data": base64]],
                    ],
                ]],
            ]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Extract the recognized text from a provider response body. Defensive:
    /// unexpected shapes throw with a body tail rather than crashing.
    public func parseText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw parseError(data, "response is not a JSON object")
        }
        switch self {
        case .claude:
            if json["stop_reason"] as? String == "refusal" {
                throw OCREngineError(engine: id,
                                     message: "request declined by safety classifiers (stop_reason: refusal)")
            }
            guard let content = json["content"] as? [[String: Any]] else {
                throw parseError(data, "missing content array")
            }
            return content.compactMap { block in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined()
        case .openai:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                throw parseError(data, "missing choices[0].message.content")
            }
            return text
        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw parseError(data, "missing candidates[0].content.parts")
            }
            return parts.compactMap { $0["text"] as? String }.joined()
        }
    }

    private func parseError(_ data: Data, _ what: String) -> OCREngineError {
        let tail = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8>"
        return OCREngineError(engine: id, message: "\(what) — body: \(tail)")
    }
}
