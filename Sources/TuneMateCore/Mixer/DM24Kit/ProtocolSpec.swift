import Foundation

/// `dm248-protocol.yaml` — 역분석한 프로토콜 명세. 코드에 박지 않고 파일로 분리해 펌웨어 버전별로 교체한다.
public struct ProtocolSpec: Equatable, Sendable {
    public enum Status: String, Sendable { case unverified, verified }
    public enum Transport: String, Sendable { case tcp, udp }
    public enum ByteOrder: String, Sendable { case little, big }
    public enum Checksum: String, Sendable { case none, sum8, xor8, crc16ccitt = "crc16_ccitt" }

    public struct Frame: Equatable, Sendable {
        public var header: [UInt8]
        public var lengthFieldSize: Int           // 0 = 없음
        public var lengthIncludesHeader: Bool
        public var addressSize: Int
        public var valueSize: Int
        public var byteOrder: ByteOrder
        public var checksum: Checksum
        public var trailer: [UInt8]
    }

    public struct Encoding: Equatable, Sendable {
        public enum Kind: String, Sendable { case linear, log, bool, table, raw }
        public var kind: Kind
        public var min: Double
        public var max: Double
        public var minRaw: Int
        public var maxRaw: Int
        /// table: raw → 값 (인덱스 = raw)
        public var table: [Double]

        /// 물리값 → raw
        public func encode(_ v: Double) -> Int {
            switch kind {
            case .bool: return v != 0 ? 1 : 0
            case .raw: return Int(v.rounded())
            case .linear:
                guard max > min else { return minRaw }
                let t = Swift.min(1, Swift.max(0, (v - min) / (max - min)))
                return minRaw + Int((t * Double(maxRaw - minRaw)).rounded())
            case .log:
                guard max > min, min > 0, v > 0 else { return minRaw }
                let t = Swift.min(1, Swift.max(0, log(v / min) / log(max / min)))
                return minRaw + Int((t * Double(maxRaw - minRaw)).rounded())
            case .table:
                guard !table.isEmpty else { return minRaw }
                var best = 0
                for (i, x) in table.enumerated() where abs(x - v) < abs(table[best] - v) { best = i }
                return minRaw + best
            }
        }

        public func decode(_ raw: Int) -> Double {
            switch kind {
            case .bool: return raw != 0 ? 1 : 0
            case .raw: return Double(raw)
            case .linear:
                guard maxRaw > minRaw else { return min }
                let t = Double(raw - minRaw) / Double(maxRaw - minRaw)
                return min + t * (max - min)
            case .log:
                guard maxRaw > minRaw, min > 0 else { return min }
                let t = Double(raw - minRaw) / Double(maxRaw - minRaw)
                return min * pow(max / min, t)
            case .table:
                let i = raw - minRaw
                return table.indices.contains(i) ? table[i] : min
            }
        }
    }

    public struct Parameter: Equatable, Sendable {
        public var name: String            // e.g. "channel.fader"
        public var addressBase: Int
        public var stride: Int             // 채널(또는 버스) 간 주소 간격
        public var bandStride: Int         // EQ 밴드 간 간격
        public var encoding: String        // encodings 키
        public var verified: Bool
    }

    public var specVersion: Int
    public var status: Status
    public var model: String
    public var firmware: String            // "unknown" 이면 검사 생략
    public var transport: Transport
    public var port: Int
    public var keepaliveIntervalMs: Int
    public var keepaliveBytes: [UInt8]
    public var handshakeSend: [UInt8]
    public var handshakeExpectPrefix: [UInt8]
    public var frame: Frame
    public var parameters: [String: Parameter]
    public var encodings: [String: Encoding]
    public var notes: [String]

    public static func load(from url: URL) throws -> ProtocolSpec {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// 패키지에 들어 있는 기본 명세 (DM24.8, 미검증 템플릿).
    public static func bundled() throws -> ProtocolSpec {
        guard let url = Bundle.module.url(forResource: "dm248-protocol", withExtension: "yaml") else {
            throw MixerError.unsupported("bundled dm248-protocol.yaml missing")
        }
        return try load(from: url)
    }

    public static func parse(_ text: String) throws -> ProtocolSpec {
        let y = try MiniYAML.parse(text)
        func bytes(_ v: YAMLValue?) -> [UInt8] { (v?.intArray ?? []).map { UInt8(truncatingIfNeeded: $0) } }
        let fr = y["frame"]
        let frame = Frame(header: bytes(fr?["header"]),
                          lengthFieldSize: fr?["length_field_size"]?.intValue ?? 0,
                          lengthIncludesHeader: fr?["length_includes_header"]?.boolValue ?? false,
                          addressSize: fr?["address_size"]?.intValue ?? 2,
                          valueSize: fr?["value_size"]?.intValue ?? 2,
                          byteOrder: ByteOrder(rawValue: fr?["byte_order"]?.stringValue ?? "little") ?? .little,
                          checksum: Checksum(rawValue: fr?["checksum"]?.stringValue ?? "none") ?? .none,
                          trailer: bytes(fr?["trailer"]))
        var params: [String: Parameter] = [:]
        for (name, v) in y["parameters"]?.dictValue ?? [] {
            params[name] = Parameter(name: name, addressBase: v["address_base"]?.intValue ?? 0, stride: v["stride"]?.intValue ?? 0,
                                     bandStride: v["band_stride"]?.intValue ?? 0, encoding: v["encoding"]?.stringValue ?? "raw",
                                     verified: v["verified"]?.boolValue ?? false)
        }
        var encs: [String: Encoding] = [:]
        for (name, v) in y["encodings"]?.dictValue ?? [] {
            let kind = Encoding.Kind(rawValue: v["kind"]?.stringValue ?? "raw") ?? .raw
            encs[name] = Encoding(kind: kind, min: v["min"]?.doubleValue ?? 0, max: v["max"]?.doubleValue ?? 1,
                                  minRaw: v["min_raw"]?.intValue ?? 0, maxRaw: v["max_raw"]?.intValue ?? 1,
                                  table: v["table"]?.arrayValue?.compactMap(\.doubleValue) ?? [])
        }
        let tr = y["transport"]
        return ProtocolSpec(specVersion: y["spec_version"]?.intValue ?? 1,
                            status: Status(rawValue: y["status"]?.stringValue ?? "unverified") ?? .unverified,
                            model: y["model"]?.stringValue ?? "TOPP PRO DM24.8",
                            firmware: y["firmware"]?.stringValue ?? "unknown",
                            transport: Transport(rawValue: tr?["kind"]?.stringValue ?? "tcp") ?? .tcp,
                            port: tr?["port"]?.intValue ?? 0,
                            keepaliveIntervalMs: tr?["keepalive_interval_ms"]?.intValue ?? 0,
                            keepaliveBytes: bytes(tr?["keepalive_bytes"]),
                            handshakeSend: bytes(y["handshake"]?["send"]),
                            handshakeExpectPrefix: bytes(y["handshake"]?["expect_prefix"]),
                            frame: frame, parameters: params, encodings: encs,
                            notes: y["notes"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    public func parameter(_ name: String) throws -> Parameter {
        guard let p = parameters[name] else { throw MixerError.unsupported("parameter \(name) not in spec") }
        return p
    }
    public func encoding(_ name: String) throws -> Encoding {
        guard let e = encodings[name] else { throw MixerError.unsupported("encoding \(name) not in spec") }
        return e
    }
}

/// 명세에 따라 바이트 프레임을 만들고 해석한다.
public struct FrameCodec: Sendable {
    public let spec: ProtocolSpec
    public init(spec: ProtocolSpec) { self.spec = spec }

    public func address(of param: ProtocolSpec.Parameter, index: Int = 0, band: Int = 0) -> Int {
        param.addressBase + index * param.stride + band * param.bandStride
    }

    public func encodeSet(parameter name: String, index: Int = 0, band: Int = 0, value: Double) throws -> [UInt8] {
        let p = try spec.parameter(name)
        let e = try spec.encoding(p.encoding)
        return frame(address: address(of: p, index: index, band: band), raw: e.encode(value))
    }

    public func frame(address: Int, raw: Int) -> [UInt8] {
        let f = spec.frame
        var body: [UInt8] = []
        body += intBytes(address, size: f.addressSize, order: f.byteOrder)
        body += intBytes(raw, size: f.valueSize, order: f.byteOrder)
        var out = f.header
        if f.lengthFieldSize > 0 {
            let len = body.count + (f.lengthIncludesHeader ? f.header.count + f.lengthFieldSize : 0) + checksumSize
            out += intBytes(len, size: f.lengthFieldSize, order: f.byteOrder)
        }
        out += body
        switch f.checksum {
        case .none: break
        case .sum8: out.append(UInt8(truncatingIfNeeded: out.reduce(0) { $0 &+ Int($1) }))
        case .xor8: out.append(out.reduce(0) { $0 ^ $1 })
        case .crc16ccitt: out += intBytes(Int(Self.crc16ccitt(out)), size: 2, order: .big)
        }
        out += f.trailer
        return out
    }

    private var checksumSize: Int {
        switch spec.frame.checksum { case .none: return 0; case .sum8, .xor8: return 1; case .crc16ccitt: return 2 }
    }

    /// 프레임 → (address, raw). 헤더·체크섬이 맞지 않으면 nil.
    public func decode(_ bytes: [UInt8]) -> (address: Int, raw: Int)? {
        let f = spec.frame
        guard bytes.count >= f.header.count + f.lengthFieldSize + f.addressSize + f.valueSize else { return nil }
        guard Array(bytes.prefix(f.header.count)) == f.header else { return nil }
        var i = f.header.count + f.lengthFieldSize
        let addr = intFrom(Array(bytes[i..<(i + f.addressSize)]), order: f.byteOrder); i += f.addressSize
        let raw = intFrom(Array(bytes[i..<(i + f.valueSize)]), order: f.byteOrder); i += f.valueSize
        switch f.checksum {
        case .none: break
        case .sum8:
            guard bytes.count > i, bytes[i] == UInt8(truncatingIfNeeded: bytes[..<i].reduce(0) { $0 &+ Int($1) }) else { return nil }
        case .xor8:
            guard bytes.count > i, bytes[i] == bytes[..<i].reduce(0, ^) else { return nil }
        case .crc16ccitt:
            guard bytes.count > i + 1, intFrom(Array(bytes[i..<(i + 2)]), order: .big) == Int(Self.crc16ccitt(Array(bytes[..<i]))) else { return nil }
        }
        return (addr, raw)
    }

    private func intBytes(_ v: Int, size: Int, order: ProtocolSpec.ByteOrder) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        for i in 0..<size { out[i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
        return order == .little ? out : out.reversed()
    }
    private func intFrom(_ b: [UInt8], order: ProtocolSpec.ByteOrder) -> Int {
        let le = order == .little ? b : b.reversed()
        var v = 0
        for (i, x) in le.enumerated() { v |= Int(x) << (8 * i) }
        return v
    }

    public static func crc16ccitt(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}
