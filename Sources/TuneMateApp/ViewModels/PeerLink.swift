import Foundation
import Combine
import MultipeerConnectivity
import TuneMateCore
#if canImport(AVFoundation)
import AVFoundation
#endif

/// 같은 Wi-Fi/블루투스 안의 튠메이트 기기끼리 지시 카드를 주고받는다 (MultipeerConnectivity).
/// 측정 기기 → 콘솔 아이패드: "이렇게 입력하세요" 카드. 콘솔 아이패드 → 측정 기기: 완료 확인.
@MainActor
final class PeerLink: NSObject, ObservableObject {
    static let serviceType = "tunemate"
    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var inbox: [Instruction] = []
    @Published private(set) var sent: [Instruction] = []
    @Published private(set) var isActive = false
    @Published var lastEvent = ""
    /// 원격 콘솔 상태 (peer 이름 → 상태)
    @Published private(set) var consoles: [String: ConsoleStatus] = [:]
    /// 지시·확인 외 메시지를 AppModel 이 처리한다
    var onMessage: ((PeerMessage, String) -> Void)?
    var onPeerConnected: ((String) -> Void)?
    var onInstructionReceived: ((Instruction) -> Void)?

    let myPeer: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private let synth = AVSpeechSynthesizer()
    private let inboxURL = AppStore.defaultRoot().appendingPathComponent("instructions.json")

    var deviceName: String { myPeer.displayName }

    override init() {
        #if os(iOS)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "Mac"
        #endif
        myPeer = MCPeerID(displayName: name)
        super.init()
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: ["app": "tunemate", "v": TuneMateInfo.version], serviceType: Self.serviceType)
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
        browser.delegate = self
        load()
    }

    func start() {
        guard !isActive else { return }
        advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers(); isActive = true
        lastEvent = "근처 튠메이트 기기를 찾는 중"
    }
    func stop() {
        advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); session.disconnect(); peers = []; isActive = false
    }

    func send(_ instruction: Instruction) -> Bool {
        guard !session.connectedPeers.isEmpty else { lastEvent = "연결된 기기가 없습니다"; return false }
        do {
            let data = try JSONEncoder().encode(PeerMessage.instruction(instruction))
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            sent.append(instruction)
            lastEvent = "\(session.connectedPeers.map(\.displayName).joined(separator: ", ")) 로 보냄"
            return true
        } catch { lastEvent = "전송 실패: \(error)"; return false }
    }

    /// 임의 메시지 전송 (연결된 모든 기기)
    @discardableResult
    func broadcast(_ msg: PeerMessage) -> Bool {
        guard !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(msg) else { return false }
        do { try session.send(data, toPeers: session.connectedPeers, with: .reliable); return true } catch { lastEvent = "전송 실패: \(error)"; return false }
    }

    /// 특정 기기로 전송
    @discardableResult
    func send(_ msg: PeerMessage, to name: String) -> Bool {
        guard let peer = session.connectedPeers.first(where: { $0.displayName == name }), let data = try? JSONEncoder().encode(msg) else { return false }
        do { try session.send(data, toPeers: [peer], with: .reliable); return true } catch { lastEvent = "전송 실패: \(error)"; return false }
    }

    /// 믹서에 연결된 콘솔 기기 (가장 최근 상태)
    var activeConsole: ConsoleStatus? { consoles.values.filter { $0.connected && $0.acceptsRemoteProposals }.max { $0.sentAt < $1.sentAt } }

    func acknowledge(_ id: UUID) {
        guard let i = inbox.firstIndex(where: { $0.id == id }) else { return }
        inbox[i].acknowledgedAt = Date(); save()
        if let data = try? JSONEncoder().encode(PeerMessage.acknowledged(id: id, by: deviceName)), !session.connectedPeers.isEmpty {
            try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
        }
    }

    var onInstructionChanged: ((Instruction) -> Void)?
    func toggleStep(_ instructionID: UUID, _ stepID: UUID) {
        guard let i = inbox.firstIndex(where: { $0.id == instructionID }), let j = inbox[i].steps.firstIndex(where: { $0.id == stepID }) else { return }
        inbox[i].steps[j].done.toggle(); save()
        onInstructionChanged?(inbox[i])
    }

    func remove(_ id: UUID) { inbox.removeAll { $0.id == id }; save() }

    /// 지시를 한국어 음성으로 읽어 준다 (콘솔 앞에서 화면을 못 볼 때).
    func speak(_ instruction: Instruction) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: instruction.spokenText)
        u.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synth.speak(u)
    }
    func stopSpeaking() { synth.stopSpeaking(at: .immediate) }

    /// 받은 쪽에서 직접 넣을 때 (같은 기기에서 지시함에 보관)
    func keepLocally(_ instruction: Instruction) { inbox.insert(instruction, at: 0); save() }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(inbox) { try? d.write(to: inboxURL, options: .atomic) }
    }
    private func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: inboxURL), let l = try? dec.decode([Instruction].self, from: d) { inbox = l }
    }
}

extension PeerLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.peers = session.connectedPeers
            self.lastEvent = "\(peerID.displayName): " + (state == .connected ? "연결됨" : state == .connecting ? "연결 중" : "끊김")
            if state == .notConnected { self.consoles.removeValue(forKey: peerID.displayName) }
            if state == .connected { self.onPeerConnected?(peerID.displayName) }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let msg = try? JSONDecoder().decode(PeerMessage.self, from: data) else { return }
        Task { @MainActor in
            switch msg {
            case .instruction(let ins):
                self.inbox.insert(ins, at: 0); self.save()
                self.lastEvent = "\(peerID.displayName) 에서 지시 받음: \(ins.title)"
                self.onInstructionReceived?(ins)
            case .acknowledged(let id, let by):
                if let i = self.sent.firstIndex(where: { $0.id == id }) { self.sent[i].acknowledgedAt = Date() }
                self.lastEvent = "\(by) 가 완료 확인"
            case .console(let st):
                self.consoles[peerID.displayName] = st
                self.onMessage?(msg, peerID.displayName)
            case .hello: break
            default:
                self.onMessage?(msg, peerID.displayName)
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerLink: MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(true, self.session) }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.lastEvent = "광고 실패: \(error.localizedDescription)" }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard !self.session.connectedPeers.contains(peerID) else { return }
            // 이름 사전순으로 한쪽만 초대해 중복 연결을 피한다
            if self.myPeer.displayName < peerID.displayName { browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 15) }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.peers = self.session.connectedPeers }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.lastEvent = "탐색 실패: \(error.localizedDescription)" }
    }
}
