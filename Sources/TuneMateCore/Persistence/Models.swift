import Foundation

/// 한 좌석 위치의 측정.
public struct PositionMeasurement: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    public var measuredAt: Date = Date()
    public var response: FrequencyResponse        // 보정 파일 적용 후, 스무딩 전
    public var irPeakTimeMs: Double?
    public var microphone: MicrophoneKind
    public init(name: String, response: FrequencyResponse, irPeakTimeMs: Double? = nil, microphone: MicrophoneKind) {
        self.name = name; self.response = response; self.irPeakTimeMs = irPeakTimeMs; self.microphone = microphone
    }
}

/// 측정 세션 (여러 위치 + 평균 + 보정 결과).
public struct MeasurementSession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var venueName: String
    public var microphone: MicrophoneKind
    public var sweep: SweepSpec
    public var positions: [PositionMeasurement] = []
    public var target: TargetCurve
    public var autoEQOptions: AutoEQOptions
    public var result: AutoEQResult?
    public var appliedToMixer: Bool = false
    public var verification: FrequencyResponse?   // 적용 후 재측정 평균 (마지막 회차)
    public var iterations: [TuningIteration] = []
    /// 반복 회차에서 관찰한 '예상−실측' 오차. 다음 계산 때 측정 응답에 더해 EQ 모델 편차를 보정한다.
    public var modelCorrection: FrequencyResponse? = nil
    public var notes: String = ""

    public init(venueName: String, microphone: MicrophoneKind, sweep: SweepSpec = .default, target: TargetCurve = .speech, autoEQOptions: AutoEQOptions = AutoEQOptions()) {
        self.venueName = venueName; self.microphone = microphone; self.sweep = sweep; self.target = target; self.autoEQOptions = autoEQOptions
    }

    public var average: FrequencyResponse? { FrequencyResponse.spatialAverage(positions.map(\.response)) }
    public var deviation: FrequencyResponse? { FrequencyResponse.spatialDeviation(positions.map(\.response)) }

    /// 평균 응답으로 보정값을 다시 계산한다.
    public mutating func recompute() {
        guard var avg = average else { result = nil; return }
        if let c = modelCorrection { avg = avg.adding(c) }
        result = AutoEQ.compute(response: avg, target: target, options: autoEQOptions)
    }

    public var currentIterationIndex: Int { iterations.count }
}

/// 앱 설정 (JSON 파일).
public struct AppSettings: Codable, Equatable, Sendable {
    public var provider: AIProviderKind = .anthropic
    public var chatTier: ModelTier = .economy
    public var analysisTier: ModelTier = .standard
    public var catalog: ModelCatalog = .default
    public var mode: OperatingMode = .proposal
    public var policy: SafetyPolicy = SafetyPolicy()
    public var venue: VenueProfile = VenueProfile()
    public var mixerFamily: MixerModel.Family = .mock
    public var mixerModelName: String = MixerModel.mock.name
    public var mixerHost: String = ""
    public var microphone: MicrophoneKind = .simulated
    public var calibrationText: String? = nil
    public var target: TargetCurve = .speech
    public var autoEQ: AutoEQOptions = AutoEQOptions()
    public var sweep: SweepSpec = .default
    public var feedback: FeedbackDetector.Options = FeedbackDetector.Options()
    public var showDisclaimerAccepted: Bool = false
    /// 앱 시작 시 기기 연결(지시함)을 자동으로 켠다 — 콘솔 아이패드용
    public var autoStartPeerLink: Bool = true
    /// 앱 시작 시 마지막 믹서에 자동 연결
    public var autoConnectMixer: Bool = false
    /// 다른 기기의 변경안을 받아 적용(콘솔 역할)
    public var actAsConsole: Bool = true

    public init() {}

    public var mixerModel: MixerModel {
        MixerModel.known.first { $0.family == mixerFamily && $0.name == mixerModelName } ?? MixerModel.known.first { $0.family == mixerFamily } ?? .mock
    }
}

/// 파일 기반 저장소: 설정 + 측정 세션들.
public actor AppStore {
    public let root: URL
    public private(set) var settings: AppSettings
    public private(set) var sessions: [MeasurementSession] = []

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TuneMate", isDirectory: true)
    }

    public init(root: URL = AppStore.defaultRoot()) {
        self.root = root
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("measurements"), withIntermediateDirectories: true)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: root.appendingPathComponent("settings.json")), let s = try? dec.decode(AppSettings.self, from: d) { settings = s } else { settings = AppSettings() }
        var loaded: [MeasurementSession] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("measurements"), includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                if let d = try? Data(contentsOf: f), let s = try? dec.decode(MeasurementSession.self, from: d) { loaded.append(s) }
            }
        }
        sessions = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }

    public func saveSettings(_ s: AppSettings) {
        settings = s
        if let d = try? encoder.encode(s) { try? d.write(to: root.appendingPathComponent("settings.json"), options: .atomic) }
    }

    public func save(_ session: MeasurementSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = session } else { sessions.insert(session, at: 0) }
        if let d = try? encoder.encode(session) { try? d.write(to: url(for: session.id), options: .atomic) }
    }

    public func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL { root.appendingPathComponent("measurements/\(id.uuidString).json") }

    public var historyDirectory: URL { root.appendingPathComponent("history", isDirectory: true) }
    public var exportsDirectory: URL { root.appendingPathComponent("exports", isDirectory: true) }
}
