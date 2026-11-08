import Foundation

/// 측정마이크 보정 파일 (miniDSP UMIK-1 형식: 헤더 + "주파수 게인[ 위상]" 줄).
public struct MicrophoneCalibration: Codable, Equatable, Sendable {
    public var serialNumber: String?
    public var sensitivityFactorDB: Double?
    public var frequencies: [Double]
    public var gainsDB: [Double]

    public init(serialNumber: String? = nil, sensitivityFactorDB: Double? = nil, frequencies: [Double], gainsDB: [Double]) {
        self.serialNumber = serialNumber
        self.sensitivityFactorDB = sensitivityFactorDB
        self.frequencies = frequencies
        self.gainsDB = gainsDB
    }

    public enum ParseError: Error, Equatable { case noData }

    public static func parse(_ text: String) throws -> MicrophoneCalibration {
        var serial: String?
        var sens: Double?
        var fs: [Double] = []
        var gs: [Double] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("\"") || lower.hasPrefix("*") || lower.hasPrefix("#") || lower.hasPrefix("sens") {
                if let r = lower.range(of: "serno:") ?? lower.range(of: "serial:") {
                    serial = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                        .split(separator: " ").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"',")) }
                }
                if let r = lower.range(of: "sens factor =") {
                    let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    let num = rest.prefix { "+-.0123456789eE".contains($0) }
                    sens = Double(num)
                }
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            guard parts.count >= 2, let f = Double(parts[0]), let g = Double(parts[1]) else { continue }
            fs.append(f); gs.append(g)
        }
        guard !fs.isEmpty else { throw ParseError.noData }
        // 주파수 오름차순 보장
        let order = fs.indices.sorted { fs[$0] < fs[$1] }
        return MicrophoneCalibration(serialNumber: serial, sensitivityFactorDB: sens,
                                     frequencies: order.map { fs[$0] }, gainsDB: order.map { gs[$0] })
    }

    /// 로그 주파수 축 선형 보간.
    public func gainDB(at hz: Double) -> Double {
        guard !frequencies.isEmpty else { return 0 }
        if hz <= frequencies[0] { return gainsDB[0] }
        if hz >= frequencies[frequencies.count - 1] { return gainsDB[gainsDB.count - 1] }
        var lo = 0, hi = frequencies.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= hz { lo = mid } else { hi = mid }
        }
        let t = log(hz / frequencies[lo]) / log(frequencies[hi] / frequencies[lo])
        return gainsDB[lo] * (1 - t) + gainsDB[hi] * t
    }

    /// 측정값에서 마이크 편차를 뺀다.
    public func apply(to r: FrequencyResponse) -> FrequencyResponse {
        FrequencyResponse(frequencies: r.frequencies,
                          magnitudesDB: zip(r.frequencies, r.magnitudesDB).map { $1 - gainDB(at: $0) })
    }
}

/// 내장 마이크용 참고 보정: 저음(<200Hz)·고음(>6kHz)이 낮게 측정되므로 공간 보정에는 쓰지 않는다.
public enum BuiltInMicPolicy {
    public static let allowedForRoomCorrection = false
    public static let allowedForFeedbackDetection = true
    public static let note = "내장 마이크는 200Hz 이하·6kHz 이상을 낮게 측정합니다. 하울링 검출 보조용으로만 씁니다."
}
