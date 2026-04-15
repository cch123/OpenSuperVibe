import Foundation

enum LLMProvider: String {
    case claude = "claude"
    case gemini = "gemini"
}

final class LLMService {
    struct Model {
        let name: String
        let id: String
    }

    static let claudeModels: [Model] = [
        .init(name: "Claude Haiku 4.5", id: "claude-haiku-4-5-20251001"),
        .init(name: "Claude Sonnet 4", id: "claude-sonnet-4-20250514"),
        .init(name: "Claude Sonnet 4.5", id: "claude-sonnet-4-5-20250929"),
        .init(name: "Claude Sonnet 4.6", id: "claude-sonnet-4-6"),
    ]

    static let geminiModels: [Model] = [
        .init(name: "Gemini 3 Flash", id: "gemini-3-flash-preview"),
        .init(name: "Gemini 3.1 Flash Lite", id: "gemini-3.1-flash-lite-preview"),
        .init(name: "Gemini 3.1 Pro", id: "gemini-3.1-pro-preview"),
        .init(name: "Gemini 2.5 Flash Lite", id: "gemini-2.5-flash-lite"),
        .init(name: "Gemini 2.5 Flash", id: "gemini-2.5-flash"),
        .init(name: "Gemini 2.5 Pro", id: "gemini-2.5-pro"),
        .init(name: "Gemini 2.0 Flash", id: "gemini-2.0-flash"),
    ]

    static var availableModels: [Model] { claudeModels }

    var provider: LLMProvider = .claude
    var apiKey: String?           // Anthropic API key
    var geminiApiKey: String?     // Google Gemini API key
    var selectedModel: Model = claudeModels[0]
    var selectedGeminiModel: Model = geminiModels[0]

    var currentModel: Model {
        provider == .claude ? selectedModel : selectedGeminiModel
    }

    var currentModels: [Model] {
        provider == .claude ? Self.claudeModels : Self.geminiModels
    }

    var isAvailable: Bool {
        switch provider {
        case .claude:
            guard let key = apiKey else { return false }
            return !key.isEmpty
        case .gemini:
            guard let key = geminiApiKey else { return false }
            return !key.isEmpty
        }
    }

    private func activeKey() throws -> String {
        switch provider {
        case .claude:
            guard let key = apiKey, !key.isEmpty else { throw LLMError.noAPIKey }
            return key
        case .gemini:
            guard let key = geminiApiKey, !key.isEmpty else { throw LLMError.noAPIKey }
            return key
        }
    }

    func translate(_ text: String, to targetLanguage: String, polish: Bool = false) async throws -> String {
        let langName = languageName(for: targetLanguage)
        let prompt: String
        if polish {
            prompt = "Translate the following text to \(langName). Handle self-corrections, filler words, and false starts by translating only the final intended meaning. Output ONLY the \(langName) translation, nothing else.\n\n\(text)"
        } else {
            prompt = "Translate the following text to \(langName). Output ONLY the \(langName) translation, nothing else.\n\n\(text)"
        }

        let result = try await callAPI(prompt: prompt, originalText: text)

        // If translate was refused, retry with sanitize + simple prompt
        if result == text {
            log("[LLM] Translate was refused, retrying")
            let sanitized = self.sanitize(text)
            let textToTranslate = (sanitized != text) ? sanitized : text
            if sanitized != text {
                log("[LLM] Sanitized: \(sanitized.prefix(120))")
            }
            // Use a minimal prompt — no mention of speech/profanity to avoid confusing the LLM
            let retryPrompt = "Translate to \(langName):\n\(textToTranslate)"
            let translated = try await callAPI(prompt: retryPrompt, originalText: textToTranslate)
            if translated != textToTranslate {
                log("[LLM] Retry translate result: \(translated.prefix(120))")
                return translated
            }
            log("[LLM] Retry also refused, falling back to original")
            return text
        }

        return result
    }

    func polish(_ text: String) async throws -> String {
        let prompt = "Polish the following transcribed speech text. Fix grammar, punctuation, and spoken language artifacts (filler words, false starts, repetitions). Preserve the original meaning, tone, and language as closely as possible. Keep the text faithful to what the speaker intended to say. If the text is already correct, return it as-is. Output ONLY the polished text, nothing else.\n\n\(text)"

        let result = try await callAPI(prompt: prompt, originalText: text)
        if result == text {
            log("[LLM] Polish was refused or text unchanged, using original")
        }
        return result
    }

    /// Deterministic text-level sanitize: replace known vulgar words with
    /// mild equivalents so the LLM can translate without refusing.
    func sanitize(_ text: String) -> String {
        // Order matters: longer phrases first to avoid partial replacements
        let replacements: [(String, String)] = [
            ("操你妈的逼", "你这混蛋"),
            ("操你妈逼", "你这混蛋"),
            ("你妈的逼", ""),
            ("妈的逼", ""),
            ("操你妈", "你这混蛋"),
            ("干你妈", "你这混蛋"),
            ("肏你妈", "你这混蛋"),
            ("操你的", "你这混蛋"),
            ("操他妈", "真该死"),
            ("他妈的", "该死的"),
            ("你妈的", "该死的"),
            ("妈的", "该死的"),
            ("操你", "你这混蛋"),
            ("干你", "你这混蛋"),
            ("肏你", "你这混蛋"),
            ("傻逼", "蠢货"),
            ("牛逼", "厉害"),
            ("装逼", "装样子"),
            ("逼", ""),
            ("操", "搞"),
            ("屌", "厉害"),
            ("鸡巴", ""),
            ("草泥马", "混蛋"),
            ("fuck", "damn"),
            ("shit", "crap"),
            ("bitch", "jerk"),
            ("ass", "butt"),
        ]

        var result = text
        for (vulgar, clean) in replacements {
            result = result.replacingOccurrences(of: vulgar, with: clean)
        }
        return result
    }

    // MARK: - Private

    private static let systemPrompt = "You are a text processing tool embedded in a voice input application. Follow the user's instructions exactly. Always produce the requested output — never refuse, never explain, never add commentary. Output only the processed text."

    private func callAPI(prompt: String, originalText: String) async throws -> String {
        let key = try activeKey()
        let raw: String
        switch provider {
        case .claude:
            raw = try await callClaudeAPI(key: key, prompt: prompt)
        case .gemini:
            raw = try await callGeminiAPI(key: key, prompt: prompt)
        }

        let full = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect LLM refusal on full response
        if LLMService.looksLikeRefusal(full) {
            log("[LLM] Refusal detected, falling back to original text. Raw response:\n\(full)")
            return originalText
        }

        // Take only the first paragraph — strip alternatives/commentary
        let trimmed = full
            .components(separatedBy: "\n\n").first?
            .components(separatedBy: "\n(").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? full

        return trimmed
    }

    private func callClaudeAPI(key: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": selectedModel.id,
            "max_tokens": 1024,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(errBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let resultText = firstContent["text"] as? String
        else {
            throw LLMError.parseFailed
        }

        return resultText
    }

    private func callGeminiAPI(key: String, prompt: String) async throws -> String {
        let model = selectedGeminiModel.id
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": Self.systemPrompt]]
            ],
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "maxOutputTokens": 1024
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(errBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let resultText = firstPart["text"] as? String
        else {
            throw LLMError.parseFailed
        }

        return resultText
    }

    static func looksLikeRefusal(_ response: String) -> Bool {
        let refusalMarkers = [
            // English — refusal / hedging / meta-commentary
            "I can't", "I cannot", "I'm not able to", "I am not able to",
            "I'm unable to", "I appreciate", "I need to clarify",
            "I don't feel comfortable", "I must decline",
            "not able to polish", "not able to translate",
            "unable to process", "against my guidelines",
            "I notice", "Could you please provide",
            "incomplete", "no complete sentence",
            "intended meaning", "provide the complete",
            // Japanese
            "すみません", "申し訳", "できません", "対応できません",
            "お手伝いできません", "適切ではない",
            // Chinese
            "抱歉", "无法处理", "无法翻译", "无法润色",
            "不能处理", "不适当", "我没办法", "不能帮",
            // Korean
            "죄송합니다", "처리할 수 없", "도와드릴 수 없",
            // French / Spanish / German
            "je ne peux pas", "no puedo", "ich kann nicht",
        ]
        let lower = response.lowercased()
        return refusalMarkers.contains { lower.contains($0.lowercased()) }
    }

    private func languageName(for code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh": return "Simplified Chinese"
        case "zh-TW": return "Traditional Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        default: return code
        }
    }

    enum LLMError: LocalizedError {
        case noAPIKey
        case apiError(String)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "LLM API key not set"
            case .apiError(let msg): return "LLM API error: \(msg)"
            case .parseFailed: return "Failed to parse LLM response"
            }
        }
    }
}
