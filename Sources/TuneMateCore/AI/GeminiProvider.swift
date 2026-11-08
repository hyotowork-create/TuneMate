import Foundation

/// Google Gemini API (generateContent, function calling). 무료·저가 등급(Flash·Flash-Lite)을 경제형에 둔다.
public struct GeminiProvider: LLMProvider {
    public let kind: AIProviderKind = .gemini
    public let apiKey: String
    public let transport: HTTPTransport
    public var baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport()) { self.apiKey = apiKey; self.transport = transport }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.gemini) }
        var body: [String: JSONValue] = [
            "contents": .array(r.messages.map(Self.encode)),
            "generationConfig": ["maxOutputTokens": .num(r.maxOutputTokens)]
        ]
        if !r.system.isEmpty { body["systemInstruction"] = ["parts": [["text": .string(r.system)]]] }
        if !r.tools.isEmpty {
            body["tools"] = [["functionDeclarations": .array(r.tools.map { ["name": .string($0.name), "description": .string($0.description), "parameters": Self.stripSchema($0.parameters)] })]]
        }
        let url = baseURL.appendingPathComponent("\(r.model):generateContent")
        let data = try JSONEncoder().encode(JSONValue.object(body))
        let (status, resp) = try await transport.post(url: url, headers: ["Content-Type": "application/json", "x-goog-api-key": apiKey], body: data)
        guard (200..<300).contains(status) else { throw LLMError.http(status: status, body: String(decoding: resp, as: UTF8.self)) }
        let j = try JSONValue.parse(resp)
        guard let cand = j["candidates"]?.arrayValue?.first else {
            let blocked = j["promptFeedback"]?["blockReason"]?.stringValue
            return LLMResponse(text: blocked.map { "요청이 차단되었습니다 (\($0))." } ?? "", toolCalls: [], usage: LLMUsage(), model: r.model, stopReason: blocked, refused: blocked != nil)
        }
        var text = ""
        var calls: [LLMToolCall] = []
        for (i, part) in (cand["content"]?["parts"]?.arrayValue ?? []).enumerated() {
            if let t = part["text"]?.stringValue { text += t }
            if let fc = part["functionCall"] {
                calls.append(LLMToolCall(id: "gemini-\(i)-\(fc["name"]?.stringValue ?? "")", name: fc["name"]?.stringValue ?? "", arguments: fc["args"] ?? .object([:])))
            }
        }
        let usage = LLMUsage(inputTokens: j["usageMetadata"]?["promptTokenCount"]?.intValue ?? 0, outputTokens: j["usageMetadata"]?["candidatesTokenCount"]?.intValue ?? 0)
        let finish = cand["finishReason"]?.stringValue
        return LLMResponse(text: text, toolCalls: calls, usage: usage, model: r.model, stopReason: finish, refused: finish == "SAFETY")
    }

    static func encode(_ m: LLMMessage) -> JSONValue {
        switch m {
        case .user(let t): return ["role": "user", "parts": [["text": .string(t)]]]
        case .assistant(let t, let calls):
            var parts: [JSONValue] = []
            if !t.isEmpty { parts.append(["text": .string(t)]) }
            for c in calls { parts.append(["functionCall": ["name": .string(c.name), "args": c.arguments]]) }
            return ["role": "model", "parts": .array(parts)]
        case .toolResults(let results):
            return ["role": "user", "parts": .array(results.map { r in
                let payload: JSONValue = (try? JSONValue.parse(r.content)) ?? ["result": .string(r.content)]
                return ["functionResponse": ["name": .string(r.name), "response": payload.objectValue != nil ? payload : ["result": payload]]]
            })]
        }
    }

    /// Gemini 는 JSON Schema 의 일부 키(additionalProperties 등)를 거부한다.
    static func stripSchema(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, val) in o where k != "additionalProperties" && k != "$schema" { out[k] = stripSchema(val) }
            return .object(out)
        case .array(let a): return .array(a.map(stripSchema))
        default: return v
        }
    }
}
