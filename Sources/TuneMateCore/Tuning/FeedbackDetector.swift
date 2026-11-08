import Foundation

/// 하울링(피드백) 후보.
public struct FeedbackCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var frequencyHz: Double
    public var levelDB: Double
    /// 주변 대역 대비 돌출(dB)
    public var prominenceDB: Double
    /// 지속 프레임 수
    public var persistenceFrames: Int
    /// 관찰 구간 동안의 증가량(dB)
    public var growthDB: Double
    /// 0~1
    public var confidence: Double
    public var firstSeen: Date
    public var lastSeen: Date
}

/// 하울링 검출기: 주변보다 뚜렷하게 솟은 좁은 피크가 일정 시간 지속하며 커지는지 본다.
/// 음악·목소리의 일시적 피크(짧고, 하모닉이 함께 있음)와 구분한다.
public final class FeedbackDetector {
    public struct Options: Codable, Equatable, Sendable {
        /// 피크가 주변(±1/3 옥타브 중앙값)보다 이만큼 커야 후보
        public var prominenceDB: Double = 12
        /// 최소 지속 프레임
        public var minPersistenceFrames: Int = 6
        /// 지속 중 최소 증가(dB). 0이면 유지만 해도 인정.
        public var minGrowthDB: Double = 2
        /// 같은 피크로 보는 주파수 허용 (옥타브 비율)
        public var trackingToleranceOctaves: Double = 1 / 24
        /// 2배음이 이만큼(dB) 이내로 함께 솟아 있으면 악기음으로 보고 신뢰도 감점
        public var harmonicPenaltyWindowDB: Double = 10
        /// 최소 절대 레벨 (dBFS). 너무 작은 신호는 무시
        public var minLevelDB: Double = -60
        public var minFrequencyHz: Double = 80
        public var maxFrequencyHz: Double = 16_000
        public init() {}
    }

    public var options: Options
    private struct Track { var freq: Double; var levels: [Double]; var prominence: Double; var first: Date; var last: Date; var missed: Int }
    private var tracks: [Track] = []

    public init(options: Options = Options()) { self.options = options }

    public func reset() { tracks.removeAll() }

    /// 프레임을 넣고 현재 확정된 후보 목록을 돌려준다.
    public func process(_ frame: SpectrumFrame) -> [FeedbackCandidate] {
        let peaks = Self.findPeaks(frame, options: options)
        var matched = [Bool](repeating: false, count: tracks.count)
        var newTracks: [Track] = []
        for p in peaks {
            if let ti = tracks.indices.first(where: { !matched[$0] && abs(log2(tracks[$0].freq / p.freq)) <= options.trackingToleranceOctaves }) {
                matched[ti] = true
                var t = tracks[ti]
                t.freq = p.freq; t.levels.append(p.level); t.prominence = p.prominence; t.last = frame.timestamp; t.missed = 0
                if t.levels.count > 40 { t.levels.removeFirst(t.levels.count - 40) }
                tracks[ti] = t
            } else {
                newTracks.append(Track(freq: p.freq, levels: [p.level], prominence: p.prominence, first: frame.timestamp, last: frame.timestamp, missed: 0))
            }
        }
        // 못 본 트랙은 2프레임 유예 뒤 제거
        for i in tracks.indices where !matched[i] { tracks[i].missed += 1 }
        tracks.removeAll { $0.missed > 2 }
        tracks.append(contentsOf: newTracks)

        return tracks.compactMap { t in
            guard t.levels.count >= options.minPersistenceFrames else { return nil }
            let growth = (t.levels.last ?? 0) - (t.levels.first ?? 0)
            // 커지는 중이거나, 충분히 오래 최고 레벨 근처에 머무는(컴프레서로 눌린 하울링) 경우
            let sustained = t.levels.count >= options.minPersistenceFrames * 2 && ((t.levels.last ?? -120) - (t.levels.max() ?? 0)) > -3
            guard growth >= options.minGrowthDB || sustained else { return nil }
            let harmonicPenalty = Self.harmonicPenalty(frame, fundamental: t.freq, options: options)
            var confidence = 0.4
            confidence += min(0.3, (t.prominence - options.prominenceDB) / 30)
            confidence += min(0.2, growth / 20)
            confidence += min(0.1, Double(t.levels.count - options.minPersistenceFrames) / 20)
            confidence -= harmonicPenalty
            return FeedbackCandidate(frequencyHz: t.freq, levelDB: t.levels.last ?? 0, prominenceDB: t.prominence,
                                     persistenceFrames: t.levels.count, growthDB: growth,
                                     confidence: max(0, min(1, confidence)), firstSeen: t.first, lastSeen: t.last)
        }.sorted { $0.confidence > $1.confidence }
    }

    struct Peak { var freq: Double; var level: Double; var prominence: Double }

    /// 고해상도 선형 스펙트럼이 있으면 그걸로, 없으면 로그 격자로 피크를 찾는다.
    static func findPeaks(_ frame: SpectrumFrame, options: Options) -> [Peak] {
        if let lin = frame.linear {
            return findPeaksLinear(lin, options: options)
        }
        return findPeaksLog(frame.response, options: options)
    }

    static func findPeaksLinear(_ s: LinearSpectrum, options: Options) -> [Peak] {
        let m = s.magnitudesDB
        var out: [Peak] = []
        let kLo = max(2, Int(options.minFrequencyHz / s.binWidthHz))
        let kHi = min(m.count - 3, Int(options.maxFrequencyHz / s.binWidthHz))
        guard kHi > kLo else { return out }
        for k in kLo...kHi {
            guard m[k] >= options.minLevelDB, m[k] > m[k - 1], m[k] >= m[k + 1], m[k] > m[k - 2], m[k] >= m[k + 2] else { continue }
            // ±1/3 옥타브 주변 중앙값 (피크 ±2 bin 제외)
            let f = s.frequency(ofBin: k)
            let lo = max(0, Int(f / pow(2, 1.0 / 3) / s.binWidthHz))
            let hi = min(m.count - 1, Int(f * pow(2, 1.0 / 3) / s.binWidthHz))
            var neigh: [Double] = []
            neigh.reserveCapacity(hi - lo + 1)
            for j in lo...hi where abs(j - k) > 2 { neigh.append(m[j]) }
            guard !neigh.isEmpty else { continue }
            neigh.sort()
            let median = neigh[neigh.count / 2]
            let prom = m[k] - median
            if prom >= options.prominenceDB {
                // 포물선 보간으로 주파수 정밀화
                let a = m[k - 1], b = m[k], c = m[k + 1]
                let denom = a - 2 * b + c
                let delta = denom != 0 ? 0.5 * (a - c) / denom : 0
                out.append(Peak(freq: (Double(k) + delta) * s.binWidthHz, level: b, prominence: prom))
            }
        }
        return out
    }

    static func findPeaksLog(_ r: FrequencyResponse, options: Options) -> [Peak] {
        let m = r.magnitudesDB
        let ppo = r.pointsPerOctave
        let w = max(2, Int(ppo / 3))
        var out: [Peak] = []
        guard m.count > 4 else { return out }
        for i in 2..<(m.count - 2) {
            let f = r.frequencies[i]
            guard f >= options.minFrequencyHz, f <= options.maxFrequencyHz, m[i] >= options.minLevelDB else { continue }
            guard m[i] > m[i - 1], m[i] >= m[i + 1] else { continue }
            var neigh: [Double] = []
            for j in max(0, i - w)...min(m.count - 1, i + w) where abs(j - i) > 1 { neigh.append(m[j]) }
            neigh.sort()
            let prom = m[i] - neigh[neigh.count / 2]
            if prom >= options.prominenceDB { out.append(Peak(freq: f, level: m[i], prominence: prom)) }
        }
        return out
    }

    /// 2배음·3배음이 함께 솟아 있으면 악기/목소리일 가능성 → 감점 (0 ~ 0.3)
    static func harmonicPenalty(_ frame: SpectrumFrame, fundamental: Double, options: Options) -> Double {
        let resp = frame.response
        let base = resp.magnitudeDB(at: fundamental)
        var penalty = 0.0
        for h in [2.0, 3.0] {
            let fh = fundamental * h
            guard fh < options.maxFrequencyHz else { continue }
            let lvl = resp.magnitudeDB(at: fh)
            let around = Decibel.fromPower((Decibel.toPower(resp.magnitudeDB(at: fh * 0.9)) + Decibel.toPower(resp.magnitudeDB(at: fh * 1.1))) / 2)
            if lvl - around > 6 && base - lvl < options.harmonicPenaltyWindowDB { penalty += 0.15 }
        }
        return penalty
    }
}
