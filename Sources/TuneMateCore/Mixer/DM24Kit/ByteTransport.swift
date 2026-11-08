import Foundation
#if canImport(Network)
import Network
#endif

/// 바이트 스트림/데이터그램 전송 추상화. 실제는 Network.framework, 테스트는 루프백.
public protocol ByteTransport: AnyObject, Sendable {
    func open(host: String, port: Int) async throws
    func close() async
    func send(_ bytes: [UInt8]) async throws
    /// 수신 스트림 (연결마다 하나)
    var incoming: AsyncStream<[UInt8]> { get async }
}

/// 테스트용 루프백: 보낸 바이트를 핸들러에 넘기고, 핸들러가 돌려준 응답을 수신 스트림에 넣는다.
public actor LoopbackTransport: ByteTransport {
    public typealias Responder = @Sendable ([UInt8]) -> [[UInt8]]
    private let responder: Responder
    private var continuation: AsyncStream<[UInt8]>.Continuation?
    private var stream: AsyncStream<[UInt8]>
    public private(set) var sent: [[UInt8]] = []
    public private(set) var isOpen = false

    public init(responder: @escaping Responder = { _ in [] }) {
        self.responder = responder
        var c: AsyncStream<[UInt8]>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.continuation = c
    }
    public func open(host: String, port: Int) async throws { isOpen = true }
    public func close() async { isOpen = false; continuation?.finish() }
    public func send(_ bytes: [UInt8]) async throws {
        guard isOpen else { throw MixerError.notConnected }
        sent.append(bytes)
        for r in responder(bytes) { continuation?.yield(r) }
    }
    public var incoming: AsyncStream<[UInt8]> { stream }
    public func inject(_ bytes: [UInt8]) { continuation?.yield(bytes) }
}

#if canImport(Network)
/// Network.framework 기반 TCP/UDP 전송.
public final class NWByteTransport: ByteTransport, @unchecked Sendable {
    public enum Kind { case tcp, udp }
    private let kind: Kind
    private let connection = Locked<NWConnection?>(nil)
    private let queue = DispatchQueue(label: "tunemate.transport")
    private var continuation: AsyncStream<[UInt8]>.Continuation?
    private let stream: AsyncStream<[UInt8]>

    public init(kind: Kind) {
        self.kind = kind
        var c: AsyncStream<[UInt8]>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { c = $0 }
        self.continuation = c
    }

    public func open(host: String, port: Int) async throws {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw MixerError.transport("bad port \(port)") }
        let params: NWParameters = kind == .tcp ? .tcp : .udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        connection.set(conn)
        let resumed = Locked(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if resumed.swap(true) == false { cont.resume() }
                    self?.receiveLoop(conn)
                case .failed(let e):
                    if resumed.swap(true) == false { cont.resume(throwing: MixerError.transport(e.localizedDescription)) }
                    self?.continuation?.finish()
                case .waiting(let e):
                    // 경로 없음(다른 네트워크·Wi-Fi 꺼짐 등). 기다리지 않고 바로 알린다.
                    if resumed.swap(true) == false { cont.resume(throwing: MixerError.transport("네트워크 경로 없음: \(e.localizedDescription)")); conn.cancel() }
                case .cancelled:
                    if resumed.swap(true) == false { cont.resume(throwing: MixerError.transport("연결이 취소되었습니다")) }
                    self?.continuation?.finish()
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6) { if resumed.get() == false { conn.cancel() } }
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        if kind == .udp {
            // UDP: 데이터그램마다 isComplete 가 true 이므로 오류가 없는 한 계속 받는다.
            conn.receiveMessage { [weak self] data, _, _, error in
                if let data, !data.isEmpty { self?.continuation?.yield([UInt8](data)) }
                if error == nil { self?.receiveLoop(conn) } else { self?.continuation?.finish() }
            }
        } else {
            // TCP: isComplete 는 상대가 연결을 닫았다는 뜻.
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                if let data, !data.isEmpty { self?.continuation?.yield([UInt8](data)) }
                if error == nil && !isComplete { self?.receiveLoop(conn) } else { self?.continuation?.finish() }
            }
        }
    }

    public func close() async {
        connection.swap(nil)?.cancel()
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard let c = connection.get() else { throw MixerError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: Data(bytes), completion: .contentProcessed { e in
                if let e { cont.resume(throwing: MixerError.transport(e.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    public var incoming: AsyncStream<[UInt8]> { stream }
}
#endif

/// 작은 잠금 상자 (Swift 6 동시성 경고 없이 공유 상태를 다루기 위함).
public final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    public init(_ v: T) { value = v }
    public func get() -> T { lock.withLock { value } }
    public func set(_ v: T) { lock.withLock { value = v } }
    @discardableResult public func swap(_ v: T) -> T { lock.withLock { let old = value; value = v; return old } }
}
