import Foundation

/// OpenAI Chat Completions API (function calling). 낮은 요금제용으로 mini 계열 모델을 경제형에 둔다.
public struct OpenAIProvider: LLMProvider {
    public let kind: AIProviderKind = .openai
    public let apiKey: String
    public let transport: HTTPTransport
    public var baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(apiKey: String, transport: HTTPTransport = URLSessionTransport()) { self.apiKey = apiKey; self.transport = transport }

    public func complete(_ r: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.openai) }
        var messages: [JSONValue] = []
        if !r.system.isEmpty { messages.append(["role": "system", "content": .string(r.system)]) }
        for m in r.messages { messages.append(contentsOf: Self.encode(m)) }
        var body: [String: JSONValue] = [
            "model": .string(r.model),
            "messages": .array(messages),
            "max_completion_tokens": .num(r.maxOutputTokens)
        ]
        if r.model.hasPrefix("gpt-5") || r.model.hasPrefix("o") { body["reasoning_effort"] = .string(r.effort.rawValue) }
        if !r.tools.isEmpty {
            body["tools"] = .array(r.tools.map { ["type": "function", "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters]] })
        }
        let data = try JSONEncoder().encode(JSONValue.object(body))
        let (status, resp) = try await transport.post(url: baseURL, headers: ["Content-Type": "application/json", "Authorization": "Bearer \(apiKey)"], body: data)
        guard (200..<300).contains(status) else { throw LLMError.http(status: status, body: String(decoding: resp, as: UTF8.self)) }
        let j = try JSONValue.parse(resp)
        guard let choice = j["choices"]?.arrayValue?.first, let msg = choice["message"] else { throw LLMError.decoding("no choices") }
        let text = msg["content"]?.stringValue ?? ""
        var calls: [LLMToolCall] = []
        for tc in msg["tool_calls"]?.arrayValue ?? [] {
            let fn = tc["function"]
            let argsStr = fn?["arguments"]?.stringValue ?? "{}"
            let args = (try? JSONValue.parse(argsStr)) ?? .object([:])
            calls.append(LLMToolCall(id: tc["id"]?.stringValue ?? UUID().uuidString, name: fn?["name"]?.stringValue ?? "", arguments: args))
        }
        let usage = LLMUsage(inputTokens: j["usage"]?["prompt_tokens"]?.intValue ?? 0, outputTokens: j["usage"]?["completion_tokens"]?.intValue ?? 0)
        let finish = choice["finish_reason"]?.stringValue
        return LLMResponse(text: text, toolCalls: calls, usage: usage, model: j["model"]?.stringValue ?? r.model, stopReason: finish, refused: finish == "content_filter")
    }

    static func encode(_ m: LLMMessage) -> [JSONValue] {
        switch m {
        case .user(let t): return [["role": "user", "content": .string(t)]]
        case .assistant(let t, let calls):
            var msg: [String: JSONValue] = ["role": "assistant", "content": .string(t)]
            if !calls.isEmpty {
                msg["tool_calls"] = .array(calls.map { ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string((try? $0.arguments.jsonString(pretty: false)) ?? "{}")]] })
            }
            return [.object(msg)]
        case .toolResults(let results):
            return results.map { ["role": "tool", "tool_call_id": .string($0.callID), "content": .string($0.content)] }
        }
    }
}
