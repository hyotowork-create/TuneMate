import Foundation

/// AI 공급자 종류. 사용자 본인 API 키로 연결한다.
public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic, openai, gemini
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .anthropic: return "Claude (Anthropic)"; case .openai: return "ChatGPT (OpenAI)"; case .gemini: return "Gemini (Google)" }
    }
    public var keyHint: String {
        switch self { case .anthropic: return "sk-ant-…  (console.anthropic.com)"; case .openai: return "sk-…  (platform.openai.com)"; case .gemini: return "AIza…  (aistudio.google.com)" }
    }
}

/// 모델 등급 — 요금제에 맞춰 고른다. 경제형은 저가 모델로 일상 대화·간단 조정, 정밀형은 측정 결과 분석.
public enum ModelTier: String, Codable, Sendable, CaseIterable, Identifiable {
    case economy, standard, precise
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .economy: return "경제형"; case .standard: return "표준"; case .precise: return "정밀" }
    }
    public var explanation: String {
        switch self {
        case .economy: return "가장 저렴한 모델. 일상 대화·간단한 조정 제안. 낮은 요금제에서 기본으로 권장."
        case .standard: return "균형형. 대화형 진단·조정 제안."
        case .precise: return "최고 성능. 측정 결과 정밀 분석·원인 설명."
        }
    }
}

/// 공급자별 등급 → 모델 ID. 설정에서 바꿀 수 있다 (모델명은 구현 시점 기준, 공급자 콘솔에서 확인).
public struct ModelCatalog: Codable, Equatable, Sendable {
    public var models: [AIProviderKind: [ModelTier: String]]

    public init(models: [AIProviderKind: [ModelTier: String]]) { self.models = models }

    public static let `default` = ModelCatalog(models: [
        .anthropic: [.economy: "claude-haiku-5-5", .standard: "claude-sonnet-5-5", .precise: "claude-opus-5-5"],
        .openai: [.economy: "gpt-5-mini", .standard: "gpt-5", .precise: "gpt-5"],
        .gemini: [.economy: "gemini-2.5-flash-lite", .standard: "gemini-2.5-flash", .precise: "gemini-2.5-pro"]
    ])

    public func model(_ provider: AIProviderKind, _ tier: ModelTier) -> String {
        models[provider]?[tier] ?? ModelCatalog.default.models[provider]?[tier] ?? ""
    }
    public mutating func set(_ provider: AIProviderKind, _ tier: ModelTier, _ id: String) {
        var m = models[provider] ?? [:]; m[tier] = id; models[provider] = m
    }
}

/// 공급자 중립 메시지 모델.
public struct LLMToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue   // JSON Schema (object)
    public init(name: String, description: String, parameters: JSONValue) { self.name = name; self.description = description; self.parameters = parameters }
}

public struct LLMToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public init(id: String, name: String, arguments: JSONValue) { self.id = id; self.name = name; self.arguments = arguments }
}

public struct LLMToolResult: Codable, Equatable, Sendable {
    public var callID: String
    public var name: String
    public var content: String
    public var isError: Bool
    public init(callID: String, name: String, content: String, isError: Bool = false) { self.callID = callID; self.name = name; self.content = content; self.isError = isError }
}

public enum LLMMessage: Codable, Equatable, Sendable {
    case user(String)
    case assistant(text: String, toolCalls: [LLMToolCall])
    case toolResults([LLMToolResult])

    public var displayText: String? {
        switch self {
        case .user(let t): return t
        case .assistant(let t, _): return t.isEmpty ? nil : t
        case .toolResults: return nil
        }
    }
}

public struct LLMUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0) { self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}

public struct LLMResponse: Equatable, Sendable {
    public var text: String
    public var toolCalls: [LLMToolCall]
    public var usage: LLMUsage
    public var model: String
    public var stopReason: String?
    public var refused: Bool
    public init(text: String, toolCalls: [LLMToolCall], usage: LLMUsage, model: String, stopReason: String? = nil, refused: Bool = false) {
        self.text = text; self.toolCalls = toolCalls; self.usage = usage; self.model = model; self.stopReason = stopReason; self.refused = refused
    }
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [LLMMessage]
    public var tools: [LLMToolDefinition]
    public var maxOutputTokens: Int
    /// 추론 깊이 힌트 (공급자별 해석: Anthropic effort, OpenAI reasoning_effort, Gemini thinking budget)
    public var effort: Effort
    public enum Effort: String, Sendable { case low, medium, high }
    public init(model: String, system: String, messages: [LLMMessage], tools: [LLMToolDefinition], maxOutputTokens: Int = 4096, effort: Effort = .medium) {
        self.model = model; self.system = system; self.messages = messages; self.tools = tools; self.maxOutputTokens = maxOutputTokens; self.effort = effort
    }
}

public enum LLMError: Error, CustomStringConvertible {
    case missingAPIKey(AIProviderKind)
    case http(status: Int, body: String)
    case decoding(String)
    case network(String)
    public var description: String {
        switch self {
        case .missingAPIKey(let p): return "\(p.displayName) API 키가 없습니다. 설정에서 등록하세요."
        case .http(let s, let b): return "API 오류 \(s): \(b.prefix(300))"
        case .decoding(let s): return "응답 해석 실패: \(s)"
        case .network(let s): return "네트워크 오류: \(s)"
        }
    }
}

public protocol LLMProvider: Sendable {
    var kind: AIProviderKind { get }
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

/// HTTP 추상화 — 테스트에서 가짜 응답을 넣는다.
public protocol HTTPTransport: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, data: Data)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, data: Data) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch { throw LLMError.network(error.localizedDescription) }
    }
}

/// 테스트용: 요청을 기록하고 미리 정한 응답을 돌려준다.
public final class StubTransport: HTTPTransport, @unchecked Sendable {
    public var responses: [(Int, Data)]
    public private(set) var requests: [(URL, [String: String], JSONValue)] = []
    private let lock = NSLock()
    public init(responses: [(Int, String)]) { self.responses = responses.map { ($0.0, Data($0.1.utf8)) } }
    public func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, data: Data) {
        let parsed = (try? JSONValue.parse(body)) ?? .null
        return lock.withLock {
            requests.append((url, headers, parsed))
            guard !responses.isEmpty else { return (500, Data("no stub".utf8)) }
            return responses.removeFirst()
        }
    }
}
