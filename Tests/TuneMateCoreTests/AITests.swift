import Testing
import Foundation
@testable import TuneMateCore

@Suite("AI providers")
struct AITests {
    let tools = [LLMToolDefinition(name: "get_meters", description: "d", parameters: ["type": "object", "properties": [:], "additionalProperties": false])]

    @Test func anthropicRequestAndToolUseParsing() async throws {
        let stub = StubTransport(responses: [(200, """
        {"id":"msg_1","model":"claude-haiku-5-5","stop_reason":"tool_use","content":[{"type":"text","text":"확인해 볼게요."},{"type":"tool_use","id":"toolu_1","name":"get_meters","input":{}}],"usage":{"input_tokens":120,"output_tokens":30}}
        """)])
        let p = AnthropicProvider(apiKey: "sk-test", transport: stub)
        let r = try await p.complete(LLMRequest(model: "claude-haiku-5-5", system: "sys", messages: [.user("1번 소리 안 나요")], tools: tools, effort: .low))
        #expect(r.text == "확인해 볼게요.")
        #expect(r.toolCalls.first?.name == "get_meters"); #expect(r.toolCalls.first?.id == "toolu_1")
        #expect(r.usage.inputTokens == 120)
        let (url, headers, body) = stub.requests[0]
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(headers["anthropic-version"] == "2026-10-21"); #expect(headers["x-api-key"] == "sk-test")
        #expect(body["model"]?.stringValue == "claude-haiku-5-5")
        #expect(body["system"]?.stringValue == "sys")
        #expect(body["output_config"]?["effort"]?.stringValue == "low")
        #expect(body["tools"]?.arrayValue?.first?["input_schema"] != nil)
        #expect(body["fallbacks"] == nil) // haiku 는 서버측 대체 미적용
        // 도구 결과 인코딩
        let enc = AnthropicProvider.encode(.toolResults([LLMToolResult(callID: "toolu_1", name: "get_meters", content: "CH1: -20")]))
        #expect(enc["role"]?.stringValue == "user")
        #expect(enc["content"]?.arrayValue?.first?["tool_use_id"]?.stringValue == "toolu_1")
    }

    @Test func anthropicFallbackHeaderOnSonnet() async throws {
        let stub = StubTransport(responses: [(200, #"{"model":"claude-sonnet-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"#)])
        let p = AnthropicProvider(apiKey: "k", transport: stub)
        _ = try await p.complete(LLMRequest(model: "claude-sonnet-5-5", system: "", messages: [.user("hi")], tools: []))
        #expect(stub.requests[0].1["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(stub.requests[0].2["fallbacks"]?.stringValue == "default")
    }

    @Test func openAIRequestAndToolCallParsing() async throws {
        let stub = StubTransport(responses: [(200, """
        {"model":"gpt-5-mini","choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"adjust_fader","arguments":"{\\"target\\":\\"CH1\\",\\"delta_db\\":2}"}}]}}],"usage":{"prompt_tokens":50,"completion_tokens":10}}
        """)])
        let p = OpenAIProvider(apiKey: "sk", transport: stub)
        let r = try await p.complete(LLMRequest(model: "gpt-5-mini", system: "sys", messages: [.user("1번 2dB 올려"), .assistant(text: "네", toolCalls: []), .toolResults([])], tools: tools))
        #expect(r.toolCalls.first?.name == "adjust_fader")
        #expect(r.toolCalls.first?.arguments["delta_db"]?.doubleValue == 2)
        let body = stub.requests[0].2
        #expect(body["messages"]?.arrayValue?.first?["role"]?.stringValue == "system")
        #expect(body["tools"]?.arrayValue?.first?["type"]?.stringValue == "function")
        #expect(body["reasoning_effort"]?.stringValue == "medium")
        #expect(stub.requests[0].1["Authorization"] == "Bearer sk")
    }

    @Test func geminiRequestAndFunctionCallParsing() async throws {
        let stub = StubTransport(responses: [(200, """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"미터를 볼게요."},{"functionCall":{"name":"get_meters","args":{}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":40,"candidatesTokenCount":12}}
        """)])
        let p = GeminiProvider(apiKey: "AIza", transport: stub)
        let r = try await p.complete(LLMRequest(model: "gemini-2.5-flash", system: "sys", messages: [.user("안녕")], tools: tools))
        #expect(r.text == "미터를 볼게요."); #expect(r.toolCalls.first?.name == "get_meters")
        let (url, headers, body) = stub.requests[0]
        #expect(url.absoluteString.hasSuffix("/models/gemini-2.5-flash:generateContent"))
        #expect(headers["x-goog-api-key"] == "AIza")
        #expect(body["systemInstruction"] != nil)
        let decl = body["tools"]?.arrayValue?.first?["functionDeclarations"]?.arrayValue?.first
        #expect(decl?["parameters"]?["additionalProperties"] == nil) // Gemini 는 거부하므로 제거
        let enc = GeminiProvider.encode(.toolResults([LLMToolResult(callID: "x", name: "get_meters", content: "CH1: -20")]))
        #expect(enc["parts"]?.arrayValue?.first?["functionResponse"]?["name"]?.stringValue == "get_meters")
    }

    @Test func missingKeyAndHTTPErrors() async throws {
        await #expect(throws: LLMError.self) { _ = try await AnthropicProvider(apiKey: "", transport: StubTransport(responses: [])).complete(LLMRequest(model: "m", system: "", messages: [], tools: [])) }
        let stub = StubTransport(responses: [(429, #"{"error":"rate"}"#)])
        await #expect(throws: LLMError.self) { _ = try await OpenAIProvider(apiKey: "k", transport: stub).complete(LLMRequest(model: "m", system: "", messages: [.user("x")], tools: [])) }
    }

    @Test func catalogTiersAndFactory() throws {
        var cat = ModelCatalog.default
        #expect(cat.model(.anthropic, .economy) == "claude-haiku-5-5")
        #expect(cat.model(.anthropic, .precise) == "claude-opus-5-5")
        cat.set(.gemini, .economy, "gemini-x")
        #expect(cat.model(.gemini, .economy) == "gemini-x")
        let secrets = InMemorySecretStore()
        let f = ProviderFactory(secrets: secrets, transport: StubTransport(responses: []))
        #expect(!f.hasKey(.openai))
        #expect(throws: LLMError.self) { _ = try f.make(.openai) }
        try secrets.set(ProviderFactory.keyName(.openai), "sk")
        #expect(f.hasKey(.openai))
        #expect(try f.make(.openai).kind == .openai)
    }

    /// 전체 루프: 가짜 Claude 가 adjust_fader 를 부르고, 리허설 자동 모드에서 적용된 뒤 최종 답을 낸다.
    @Test func sessionToolLoopAppliesChangeThroughSafetyLayer() async throws {
        let drv = MockMixerDriver(); try await drv.connect(host: "sim")
        let exec = ChangeExecutor(driver: drv, history: ChangeHistoryStore(), mode: .rehearsalAuto)
        let toolExec = AssistantToolExecutor(executor: exec)
        let session = AssistantSession(tools: toolExec)
        let stub = StubTransport(responses: [
            (200, #"{"model":"claude-haiku-5-5","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"adjust_fader","input":{"target":"CH1","delta_db":2,"reason":"설교 마이크 작음"}}],"usage":{"input_tokens":1,"output_tokens":1}}"#),
            (200, #"{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"1번 설교 마이크를 2 dB 올렸습니다."}],"usage":{"input_tokens":1,"output_tokens":1}}"#)
        ])
        let provider = AnthropicProvider(apiKey: "k", transport: stub)
        let ctx = AssistantContext(venue: VenueProfile(), mode: .rehearsalAuto, mixerModel: .mock, measurement: nil)
        let answer = try await session.send("1번 마이크 소리가 작아요", provider: provider, model: "claude-haiku-5-5", context: ctx)
        #expect(answer == "1번 설교 마이크를 2 dB 올렸습니다.")
        let s = try await drv.snapshot()
        #expect(abs((s.channel(1)?.faderDB ?? 0) - (-8)) < 1e-9)
        // 두 번째 요청에 도구 결과가 들어갔다
        let second = stub.requests[1].2
        let msgs = second["messages"]?.arrayValue ?? []
        #expect(msgs.count == 3)
        #expect(msgs[2]["content"]?.arrayValue?.first?["type"]?.stringValue == "tool_result")
        #expect(msgs[2]["content"]?.arrayValue?.first?["content"]?.stringValue?.contains("적용됨") == true)
        #expect(second["system"]?.stringValue?.contains("리허설 자동 모드") == true)
        let turns = await session.turns
        #expect(turns.contains { $0.role == .tool && $0.text == "adjust_fader" })
    }

    @Test func serviceLockRefusesViaTools() async throws {
        let drv = MockMixerDriver(); try await drv.connect(host: "sim")
        let exec = ChangeExecutor(driver: drv, history: ChangeHistoryStore(), mode: .serviceLock)
        let toolExec = AssistantToolExecutor(executor: exec)
        let r = await toolExec.execute(LLMToolCall(id: "1", name: "adjust_fader", arguments: ["target": "CH1", "delta_db": 2]))
        #expect(r.content.contains("예배 잠금"))
        let p = await toolExec.execute(LLMToolCall(id: "2", name: "propose_changes", arguments: ["rationale": "t", "changes": [["kind": "mute", "target": "CH3", "on": true]]]))
        #expect(p.content.contains("CH3 뮤트"))
    }
}
