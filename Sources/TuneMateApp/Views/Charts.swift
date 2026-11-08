import SwiftUI
import Charts
import TuneMateCore

struct ChartPoint: Identifiable {
    let id = UUID()
    let series: String
    let hz: Double
    let db: Double
}

/// 로그 주파수 축 응답 차트. 여러 시리즈를 겹쳐 그린다.
struct ResponseChart: View {
    var series: [(name: String, response: FrequencyResponse)]
    var decimate = 2

    var points: [ChartPoint] {
        series.flatMap { s in
            stride(from: 0, to: s.response.count, by: decimate).map { ChartPoint(series: s.name, hz: s.response.frequencies[$0], db: s.response.magnitudesDB[$0]) }
        }
    }

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Hz", p.hz), y: .value("dB", p.db))
                .foregroundStyle(by: .value("시리즈", p.series))
                .interpolationMethod(.catmullRom)
        }
        .chartXScale(domain: 20...20_000, type: .log)
        .chartXAxis {
            AxisMarks(values: [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]) { v in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let d = v.as(Double.self) { Text(d >= 1000 ? "\(Int(d / 1000))k" : "\(Int(d))") } }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxisLabel("dB")
        .frame(minHeight: 220)
    }
}
