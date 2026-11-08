import Foundation

/// 노치 배치 계획: 해당 채널의 빈 PEQ 밴드 → 없으면 메인 출력 EQ → 없으면 게인 낮추기 안내.
public struct NotchPolicy: Codable, Equatable, Sendable {
    public var stepDB: Double = -3
    public var maxDepthDB: Double = -12
    public var q: Double = 10
    /// 기존 노치와 이 범위(옥타브) 안이면 새로 만들지 않고 깊게 한다
    public var mergeToleranceOctaves: Double = 1 / 12
    public init() {}
}

public enum NotchPlan: Equatable, Sendable {
    case newBand(target: EQTarget, band: Int, filter: EQFilter)
    case deepenBand(target: EQTarget, band: Int, newGainDB: Double)
    case noBandAvailable(advice: String)
    case depthLimitReached(target: EQTarget, band: Int, advice: String)
}

public enum NotchPlanner {
    /// - Parameters:
    ///   - channelEQ: 하울링이 나는 채널의 EQ (nil이면 채널을 모를 때)
    ///   - mainEQ: 메인 출력 EQ
    public static func plan(frequencyHz: Double, channel: EQTarget?, channelEQ: [EQBand]?, mainEQ: [EQBand], policy: NotchPolicy = NotchPolicy()) -> NotchPlan {
        var candidates: [(EQTarget, [EQBand])] = []
        if let ch = channel, let eq = channelEQ { candidates.append((ch, eq)) }
        candidates.append((.mainLR, mainEQ))

        // 1) 기존 노치 근처면 깊게
        for (target, bands) in candidates {
            if let b = bands.first(where: { $0.enabled && $0.gainDB < 0 && abs(log2($0.frequencyHz / frequencyHz)) <= policy.mergeToleranceOctaves }) {
                let newGain = b.gainDB + policy.stepDB
                if newGain < policy.maxDepthDB - 1e-9 {
                    return .depthLimitReached(target: target, band: b.index, advice: "노치 한도(\(Int(policy.maxDepthDB)) dB)에 닿았습니다. 해당 마이크 게인을 2~3 dB 낮추거나 스피커와의 거리·각도를 조정하세요.")
                }
                return .deepenBand(target: target, band: b.index, newGainDB: newGain)
            }
        }
        // 2) 빈 밴드
        for (target, bands) in candidates {
            if let free = bands.first(where: { !$0.enabled || abs($0.gainDB) < 0.05 }) {
                return .newBand(target: target, band: free.index,
                                filter: EQFilter(type: .peaking, frequencyHz: AutoEQ.roundFrequency(frequencyHz), gainDB: policy.stepDB, q: policy.q))
            }
        }
        return .noBandAvailable(advice: "빈 EQ 밴드가 없습니다. 효과가 작은 기존 밴드를 비우거나, 마이크 게인을 낮추세요.")
    }
}
