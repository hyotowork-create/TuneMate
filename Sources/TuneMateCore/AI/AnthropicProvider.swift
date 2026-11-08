import Foundation

/// Claude Messages API (raw HTTP). 도구 사용(tool use) 루프의 한 턴을 처리한다.
public struct AnthropicProvider: LLMProvider {
    public let kind: AIProviderKind = .anthropic
    public let apiKey: String
    public let transport: HTTPTransport
    public var baseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Claude Opus 5.5·Sonnet 5.5 에서 안전 분류기 거절 시 서버 측 대체 모델로 재시도 (기본 켬)
    public var enableServerSideFallback = true

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport()) { self.apiKey = apiKey; self.transport = transport }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.anthropic) }
        var body: [String: JSONValue] = [
            "model": .string(r.model),
            "max_tokens": .num(r.maxOutputTokens),
            "messages": .array(r.messages.map(Self.encode)),
            "output_config": ["effort": .string(r.effort.rawValue)]
        ]
        if !r.system.isEmpty { body["system"] = .string(r.system) }
        if !r.tools.isEmpty {
            body["tools"] = .array(r.tools.map { ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters] })
        }
        var headers = ["Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2026-10-21"]
        let supportsFallback = r.model.hasPrefix("claude-opus-5-5") || r.model.hasPrefix("claude-sonnet-5-5") || r.model.hasPrefix("claude-fable")
        if enableServerSideFallback && supportsFallback {
            body["fallbacks"] = .string("default")
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        let data = try JSONEncoder().encode(JSONValue.object(body))
        let (status, resp) = try await transport.post(url: baseURL, headers: headers, body: data)
        guard (200..<300).contains(status) else { throw LLMError.http(status: status, body: String(decoding: resp, as: UTF8.self)) }
        let j = try JSONValue.parse(resp)
        var text = ""
        var calls: [LLMToolCall] = []
        for block in j["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text": text += block["text"]?.stringValue ?? ""
            case "tool_use":
                calls.append(LLMToolCall(id: block["id"]?.stringValue ?? UUID().uuidString, name: block["name"]?.stringValue ?? "", arguments: block["input"] ?? .object([:])))
            default: break
            }
        }
        let stop = j["stop_reason"]?.stringValue
        let usage = LLMUsage(inputTokens: j["usage"]?["input_tokens"]?.intValue ?? 0, outputTokens: j["usage"]?["output_tokens"]?.intValue ?? 0)
        if stop == "refusal" && text.isEmpty { text = "요청이 안전 정책으로 거절되었습니다. 다른 표현으로 다시 물어보세요." }
        return LLMResponse(text: text, toolCalls: calls, usage: usage, model: j["model"]?.stringValue ?? r.model, stopReason: stop, refused: stop == "refusal")
    }

    static func encode(_ m: LLMMessage) -> JSONValue {
        switch m {
        case .user(let t): return ["role": "user", "content": .string(t)]
        case .assistant(let t, let calls):
            var blocks: [JSONValue] = []
            if !t.isEmpty { blocks.append(["type": "text", "text": .string(t)]) }
            for c in calls { blocks.append(["type": "tool_use", "id": .string(c.id), "name": .string(c.name), "input": c.arguments]) }
            if blocks.isEmpty { blocks.append(["type": "text", "text": "(no content)"]) }
            return ["role": "assistant", "content": .array(blocks)]
        case .toolResults(let results):
            return ["role": "user", "content": .array(results.map { ["type": "tool_result", "tool_use_id": .string($0.callID), "content": .string($0.content), "is_error": .bool($0.isError)] })]
        }
    }
}
