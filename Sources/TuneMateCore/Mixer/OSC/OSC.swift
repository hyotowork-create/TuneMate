import Foundation

/// OSC 1.0 메시지 (i, f, s, b 타입).
public struct OSCMessage: Equatable, Sendable, CustomStringConvertible {
    public enum Argument: Equatable, Sendable {
        case int(Int32), float(Float), string(String), blob([UInt8])
        public var intValue: Int? { switch self { case .int(let i): return Int(i); case .float(let f): return Int(f); default: return nil } }
        public var floatValue: Float? { switch self { case .float(let f): return f; case .int(let i): return Float(i); default: return nil } }
        public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
        public var blobValue: [UInt8]? { if case .blob(let b) = self { return b }; return nil }
    }
    public var address: String
    public var arguments: [Argument]

    public init(_ address: String, _ arguments: [Argument] = []) { self.address = address; self.arguments = arguments }
    public init(_ address: String, _ arguments: Argument...) { self.address = address; self.arguments = arguments }

    public var description: String {
        address + " " + arguments.map {
            switch $0 {
            case .int(let i): return "\(i)"
            case .float(let f): return String(format: "%.4f", f)
            case .string(let s): return "\"\(s)\""
            case .blob(let b): return "<blob \(b.count)>"
            }
        }.joined(separator: " ")
    }

    public func encode() -> [UInt8] {
        var out = Self.paddedString(address)
        var tags = ","
        for a in arguments {
            switch a { case .int: tags += "i"; case .float: tags += "f"; case .string: tags += "s"; case .blob: tags += "b" }
        }
        out += Self.paddedString(tags)
        for a in arguments {
            switch a {
            case .int(let i): out += Self.be32(UInt32(bitPattern: i))
            case .float(let f): out += Self.be32(f.bitPattern)
            case .string(let s): out += Self.paddedString(s)
            case .blob(let b):
                out += Self.be32(UInt32(b.count)); out += b
                while out.count % 4 != 0 { out.append(0) }
            }
        }
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> OSCMessage? {
        var pos = 0
        guard let address = readString(bytes, &pos), address.hasPrefix("/") else { return nil }
        var args: [Argument] = []
        if pos < bytes.count, bytes[pos] == UInt8(ascii: ",") {
            guard let tags = readString(bytes, &pos) else { return nil }
            for t in tags.dropFirst() {
                switch t {
                case "i": guard let v = read32(bytes, &pos) else { return nil }; args.append(.int(Int32(bitPattern: v)))
                case "f": guard let v = read32(bytes, &pos) else { return nil }; args.append(.float(Float(bitPattern: v)))
                case "s": guard let s = readString(bytes, &pos) else { return nil }; args.append(.string(s))
                case "b":
                    guard let n = read32(bytes, &pos), pos + Int(n) <= bytes.count else { return nil }
                    args.append(.blob(Array(bytes[pos..<(pos + Int(n))]))); pos += Int(n)
                    while pos % 4 != 0 { pos += 1 }
                default: return nil
                }
            }
        }
        return OSCMessage(address, args)
    }

    static func paddedString(_ s: String) -> [UInt8] {
        var b = Array(s.utf8); b.append(0)
        while b.count % 4 != 0 { b.append(0) }
        return b
    }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func readString(_ b: [UInt8], _ pos: inout Int) -> String? {
        guard pos < b.count, let end = b[pos...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[pos..<end], as: UTF8.self)
        pos = end + 1
        while pos % 4 != 0 { pos += 1 }
        return s
    }
    static func read32(_ b: [UInt8], _ pos: inout Int) -> UInt32? {
        guard pos + 4 <= b.count else { return nil }
        let v = UInt32(b[pos]) << 24 | UInt32(b[pos + 1]) << 16 | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3])
        pos += 4
        return v
    }
}

/// 요청/응답 상관(같은 주소로 응답)과 비요청 메시지 스트림을 제공하는 OSC 클라이언트.
public actor OSCClient {
    private let transport: any ByteTransport
    private var waiters: [String: [Waiter]] = [:]
    private var receiveTask: Task<Void, Never>?
    private var unsolicited: AsyncStream<OSCMessage>.Continuation?
    public let unsolicitedMessages: AsyncStream<OSCMessage>
    public var timeoutNanoseconds: UInt64 = 800_000_000
    public private(set) var isOpen = false

    public init(transport: any ByteTransport) {
        self.transport = transport
        var c: AsyncStream<OSCMessage>.Continuation!
        self.unsolicitedMessages = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c = $0 }
        self.unsolicited = c
    }

    public func setTimeout(seconds: Double) { timeoutNanoseconds = UInt64(seconds * 1_000_000_000) }

    public func open(host: String, port: Int) async throws {
        try await withTimeout(seconds: 5) { [transport] in try await transport.open(host: host, port: port) }
        isOpen = true
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.incoming
            for await bytes in stream {
                if let m = OSCMessage.decode(bytes) { await self.dispatch(m) }
            }
        }
    }

    public func close() async {
        receiveTask?.cancel()
        await transport.close()
        isOpen = false
        for (_, ws) in waiters { for w in ws { w.resume(.failure(MixerError.notConnected)) } }
        waiters.removeAll()
    }

    private func dispatch(_ m: OSCMessage) {
        if var ws = waiters[m.address], !ws.isEmpty {
            let w = ws.removeFirst()
            waiters[m.address] = ws
            w.resume(.success(m))
        } else {
            unsolicited?.yield(m)
        }
    }

    /// 응답을 기다리지 않고 보낸다.
    public func send(_ m: OSCMessage) async throws {
        guard isOpen else { throw MixerError.notConnected }
        try await transport.send(m.encode())
    }

    /// 보낸 뒤 같은 주소(또는 replyAddress)의 응답을 기다린다. 시간 초과면 대기자를 정리하고 throw 한다.
    public func request(_ m: OSCMessage, replyAddress: String? = nil) async throws -> OSCMessage {
        guard isOpen else { throw MixerError.notConnected }
        let key = replyAddress ?? m.address
        let timeout = timeoutNanoseconds
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OSCMessage, Error>) in
            let done = Locked(false)
            let waiter = Waiter { result in
                if done.swap(true) == false { cont.resume(with: result) }
            }
            waiters[key, default: []].append(waiter)
            Task { [transport] in try? await transport.send(m.encode()) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard let self else { return }
                await self.expire(waiter, key: key)
            }
        }
    }

    final class Waiter: @unchecked Sendable {
        let id = UUID()
        let resume: (Result<OSCMessage, Error>) -> Void
        init(_ r: @escaping (Result<OSCMessage, Error>) -> Void) { resume = r }
    }

    private func expire(_ w: Waiter, key: String) {
        if let i = waiters[key]?.firstIndex(where: { $0.id == w.id }) {
            waiters[key]?.remove(at: i)
            w.resume(.failure(MixerError.timeout))
        }
    }

}
