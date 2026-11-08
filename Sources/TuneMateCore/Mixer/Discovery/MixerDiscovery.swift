import Foundation

/// 네트워크에서 찾은 믹서.
public struct DiscoveredMixer: Identifiable, Equatable, Sendable, Codable {
    public var id: String { "\(host):\(port)" }
    public var host: String
    public var port: Int
    public var model: MixerModel
    public var reportedName: String
    public var reportedModel: String
    public var firmware: String?
    /// 0~1. 공개 식별 응답(/xinfo, devinfo)이면 1.0, 포트 추정이면 0.4.
    public var confidence: Double
    public var method: String

    public init(host: String, port: Int, model: MixerModel, reportedName: String, reportedModel: String, firmware: String?, confidence: Double, method: String) {
        self.host = host; self.port = port; self.model = model; self.reportedName = reportedName; self.reportedModel = reportedModel
        self.firmware = firmware; self.confidence = confidence; self.method = method
    }
}

/// 모델 식별 규칙.
public enum MixerIdentifier {
    /// Behringer/Midas `/xinfo` 응답의 model 문자열로 모델을 고른다.
    public static func identifyBehringer(modelString: String) -> MixerModel? {
        let m = modelString.uppercased()
        if m.contains("XR18") || m.contains("MR18") { return .xr18 }
        if m.contains("XR16") { return .xr16 }
        if m.contains("XR12") || m.contains("MR12") { return .xr12 }
        if m.contains("X32") || m.contains("M32") { return .x32 }
        return nil
    }

    /// Yamaha `devinfo productname` 응답.
    public static func identifyYamaha(productName: String) -> MixerModel? {
        let p = productName.uppercased()
        if p.contains("DM7") { return .dm7 }
        if p.contains("DM3") { return .dm3 }
        if p.contains("TF") || p.contains("CL") || p.contains("QL") || p.contains("RIVAGE") {
            var m = MixerModel.dm7; m.name = "Yamaha \(productName)"; return m
        }
        return nil
    }

    /// `/xinfo ,ssss ip name model fw` 메시지 → DiscoveredMixer
    public static func fromXInfo(_ m: OSCMessage, host: String, port: Int) -> DiscoveredMixer? {
        guard m.address == "/xinfo" else { return nil }
        let s = m.arguments.compactMap(\.stringValue)
        guard s.count >= 3 else { return nil }
        let modelStr = s[2]
        guard let model = identifyBehringer(modelString: modelStr) else { return nil }
        return DiscoveredMixer(host: s[0].isEmpty ? host : s[0], port: port, model: model, reportedName: s[1], reportedModel: modelStr,
                               firmware: s.count > 3 ? s[3] : nil, confidence: 1.0, method: "OSC /xinfo")
    }
}

/// UDP 브로드캐스트 /xinfo + Yamaha RCP 포트 탐지 + DM24.8 명세 기반 탐지.
public actor MixerDiscovery {
    public init() {}

    public struct Options: Sendable {
        public var timeoutSeconds: Double = 2.0
        /// Yamaha RCP(TCP 49280) 탐지를 시도할 호스트 목록 (서브넷 전체 스캔은 비용이 커서 명시 호스트만)
        public var yamahaHosts: [String] = []
        /// DM24.8 명세 포트가 정해졌을 때 탐지할 호스트
        public var dm248Hosts: [String] = []
        public var dm248Spec: ProtocolSpec? = nil
        public init() {}
    }

    public func scan(options: Options = Options()) async -> [DiscoveredMixer] {
        var found: [DiscoveredMixer] = []
        // 1) Behringer/Midas: 10023(X32) · 10024(X-Air) 브로드캐스트
        let targets = ["255.255.255.255"] + UDPBroadcaster.localBroadcastAddresses()
        for port in [10023, 10024] {
            var replies: [(host: String, bytes: [UInt8])] = []
            for addr in targets {
                replies += UDPBroadcaster.broadcastAndCollect(payload: OSCMessage("/xinfo").encode(), port: port, timeoutSeconds: options.timeoutSeconds / Double(targets.count), broadcastAddress: addr)
            }
            for (host, bytes) in replies {
                if let m = OSCMessage.decode(bytes), let d = MixerIdentifier.fromXInfo(m, host: host, port: port), !found.contains(where: { $0.id == d.id }) {
                    found.append(d)
                }
            }
        }
        // 2) Yamaha RCP
        for host in options.yamahaHosts {
            let t = NWByteTransport(kind: .tcp)
            let drv = YamahaRCPDriver(model: .dm3, transport: t)
            if (try? await drv.connect(host: host)) != nil {
                let name = await drv.productName ?? "Yamaha"
                let fw = await drv.firmware
                await drv.disconnect()
                let model = MixerIdentifier.identifyYamaha(productName: name) ?? .dm3
                found.append(DiscoveredMixer(host: host, port: YamahaRCPDriver.port, model: model, reportedName: name, reportedModel: name, firmware: fw, confidence: 1.0, method: "Yamaha RCP devinfo"))
            }
        }
        // 3) DM24.8: 명세 포트가 있으면 연결 시도만으로 '추정' 등록
        if let spec = options.dm248Spec, spec.port > 0 {
            for host in options.dm248Hosts {
                let t = NWByteTransport(kind: spec.transport == .tcp ? .tcp : .udp)
                if (try? await t.open(host: host, port: spec.port)) != nil {
                    await t.close()
                    found.append(DiscoveredMixer(host: host, port: spec.port, model: .dm248, reportedName: "DM24.8?", reportedModel: spec.model, firmware: nil, confidence: 0.4, method: "포트 \(spec.port) 응답 (추정)"))
                }
            }
        }
        return found
    }
}

/// 드라이버 생성.
public enum MixerDriverFactory {
    public static func make(for model: MixerModel, dm248Spec: ProtocolSpec? = nil) throws -> any MixerDriver {
        switch model.family {
        case .mock: return MockMixerDriver(model: model)
        case .behringerX32: return BehringerOSCDriver(model: model, dialect: .x32, transport: NWByteTransport(kind: .udp))
        case .behringerXAir: return BehringerOSCDriver(model: model, dialect: .xair(channels: model.channelCount, buses: model.auxCount), transport: NWByteTransport(kind: .udp))
        case .yamahaDM: return YamahaRCPDriver(model: model, transport: NWByteTransport(kind: .tcp))
        case .toppProDM24:
            let spec = try dm248Spec ?? ProtocolSpec.bundled()
            return DM24Driver(spec: spec, transport: NWByteTransport(kind: spec.transport == .tcp ? .tcp : .udp), model: model)
        case .allenHeathSQ: throw MixerError.unsupported("Allen & Heath SQ 드라이버는 아직 없습니다 (MIDI over TCP 51325).")
        }
    }
}
