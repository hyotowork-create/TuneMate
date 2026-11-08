import Foundation

public struct ChangeLogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var timestamp: Date = Date()
    public var proposalID: UUID
    public var source: ProposalSource
    public var mode: OperatingMode
    public var summaries: [String]
    public var approvedBy: String      // "auto" | "user"
    public var snapshotID: UUID?
    public var undone: Bool = false
    public var error: String?

    public init(proposalID: UUID, source: ProposalSource, mode: OperatingMode, summaries: [String], approvedBy: String, snapshotID: UUID?) {
        self.proposalID = proposalID; self.source = source; self.mode = mode; self.summaries = summaries; self.approvedBy = approvedBy; self.snapshotID = snapshotID
    }
}

public struct MixerSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var takenAt: Date = Date()
    public var reason: String
    public var state: MixerState
}

/// 스냅샷·변경 로그를 JSON 파일로 남긴다.
public actor ChangeHistoryStore {
    private let directory: URL
    public private(set) var snapshots: [MixerSnapshot] = []
    public private(set) var log: [ChangeLogEntry] = []
    public var maxSnapshots = 50

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: directory.appendingPathComponent("snapshots.json")), let s = try? dec.decode([MixerSnapshot].self, from: d) { snapshots = s }
        if let d = try? Data(contentsOf: directory.appendingPathComponent("changelog.json")), let l = try? dec.decode([ChangeLogEntry].self, from: d) { log = l }
    }

    /// 메모리 전용 (테스트)
    public init() {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunemate-ephemeral-\(UUID().uuidString)")
    }

    private var snapshotsURL: URL { directory.appendingPathComponent("snapshots.json") }
    private var logURL: URL { directory.appendingPathComponent("changelog.json") }

    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? enc.encode(snapshots) { try? d.write(to: snapshotsURL, options: .atomic) }
        if let d = try? enc.encode(log) { try? d.write(to: logURL, options: .atomic) }
    }

    @discardableResult
    public func addSnapshot(_ state: MixerState, reason: String) -> MixerSnapshot {
        let s = MixerSnapshot(reason: reason, state: state)
        snapshots.append(s)
        if snapshots.count > maxSnapshots { snapshots.removeFirst(snapshots.count - maxSnapshots) }
        persist()
        return s
    }

    public func snapshot(id: UUID) -> MixerSnapshot? { snapshots.first { $0.id == id } }

    public func append(_ e: ChangeLogEntry) { log.append(e); persist() }
    public func markUndone(_ id: UUID) {
        if let i = log.firstIndex(where: { $0.id == id }) { log[i].undone = true; persist() }
    }
    public var lastUndoable: ChangeLogEntry? { log.last { !$0.undone && $0.snapshotID != nil && $0.error == nil } }
}
