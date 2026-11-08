import Foundation

/// 입력한 IP 로 믹서에 직접 연결해 보는 테스트. 탐색(브로드캐스트)이 막힌 네트워크에서도 쓴다.
public struct ProbeResult: Equatable, Sendable {
    public var ok: Bool
    public var host: String
    public var port: Int
    public var model: MixerModel?
    public var reportedName: String
    public var reportedModel: String
    public var firmware: String?
    public var roundTripMs: Double?
    public var message: String
}

public enum MixerProbe {
    /// family 에 맞는 프로토콜로 host 를 두드린다.
    public static func probe(host: String, family: MixerModel.Family, dm248Spec: ProtocolSpec? = nil, timeoutSeconds: Double = 3) async -> ProbeResult {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return fail(h, 0, "IP 주소를 입력하세요.") }
        let start = Date()
        func ms() -> Double { Date().timeIntervalSince(start) * 1000 }
        switch family {
        case .behringerX32, .behringerXAir:
            let port = family == .behringerX32 ? 10023 : 10024
            let client = OSCClient(transport: NWByteTransport(kind: .udp))
            await client.setTimeout(seconds: timeoutSeconds)
            do {
                try await client.open(host: h, port: port)
                let r = try await client.request(OSCMessage("/xinfo"))
                await client.close()
                let s = r.arguments.compactMap(\.stringValue)
                let model = s.count > 2 ? MixerIdentifier.identifyBehringer(modelString: s[2]) : nil
                return ProbeResult(ok: true, host: h, port: port, model: model, reportedName: s.count > 1 ? s[1] : "", reportedModel: s.count > 2 ? s[2] : "",
                                   firmware: s.count > 3 ? s[3] : nil, roundTripMs: ms(), message: "응답 받음: \(s.joined(separator: " / "))")
            } catch {
                await client.close()
                return fail(h, port, "응답 없음 (\(error)). 같은 Wi-Fi/LAN 인지, 믹서 IP 가 맞는지, UDP \(port) 가 막히지 않았는지 확인하세요.")
            }
        case .yamahaDM:
            let drv = YamahaRCPDriver(model: .dm3, transport: NWByteTransport(kind: .tcp))
            do {
                try await withTimeout(seconds: timeoutSeconds) { try await drv.connect(host: h) }
                let name = await drv.productName ?? "Yamaha"
                let fw = await drv.firmware
                await drv.disconnect()
                return ProbeResult(ok: true, host: h, port: YamahaRCPDriver.port, model: MixerIdentifier.identifyYamaha(productName: name), reportedName: name, reportedModel: name, firmware: fw, roundTripMs: ms(), message: "RCP 응답: \(name)")
            } catch {
                await drv.disconnect()
                return fail(h, YamahaRCPDriver.port, "RCP(TCP 49280) 연결 실패 (\(error)). 믹서 네트워크 설정에서 원격 제어가 켜져 있는지 확인하세요.")
            }
        case .toppProDM24:
            let spec = (try? dm248Spec ?? ProtocolSpec.bundled())
            guard let spec, spec.port > 0 else { return fail(h, 0, "DM24.8 제어 포트가 아직 확정되지 않았습니다 (Phase 0 캡처 필요). 연결 테스트는 명세에 포트를 채운 뒤 가능합니다.") }
            let t = NWByteTransport(kind: spec.transport == .tcp ? .tcp : .udp)
            do {
                try await withTimeout(seconds: timeoutSeconds) { try await t.open(host: h, port: spec.port) }
                await t.close()
                return ProbeResult(ok: true, host: h, port: spec.port, model: .dm248, reportedName: "DM24.8?", reportedModel: spec.model, firmware: nil, roundTripMs: ms(), message: "포트 \(spec.port) 응답 (추정). 프로토콜 status=\(spec.status.rawValue)")
            } catch {
                await t.close()
                return fail(h, spec.port, "포트 \(spec.port) 연결 실패 (\(error)).")
            }
        case .allenHeathSQ:
            return fail(h, 51325, "Allen & Heath SQ 드라이버는 아직 없습니다.")
        case .mock:
            return ProbeResult(ok: true, host: "sim", port: 0, model: .mock, reportedName: "시뮬레이터", reportedModel: "mock", firmware: "sim-1.0", roundTripMs: 0, message: "시뮬레이터는 항상 연결됩니다.")
        }
    }

    static func fail(_ h: String, _ p: Int, _ m: String) -> ProbeResult {
        ProbeResult(ok: false, host: h, port: p, model: nil, reportedName: "", reportedModel: "", firmware: nil, roundTripMs: nil, message: m)
    }
}

/// 시간 제한 래퍼. 본문이 취소에 응답하지 않아도(네트워크 콜백 대기 등) 호출자는 제시간에 돌아온다.
public func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let done = Locked(false)
        let work = Task {
            do { let v = try await body(); if done.swap(true) == false { cont.resume(returning: v) } }
            catch { if done.swap(true) == false { cont.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if done.swap(true) == false { work.cancel(); cont.resume(throwing: MixerError.timeout) }
        }
    }
}
