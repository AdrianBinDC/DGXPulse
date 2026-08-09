import Foundation

enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case fiveMinutes
    case thirtyMinutes
    case oneHour
    case twelveHours
    case twentyFourHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneMinute: return "1m"
        case .fiveMinutes: return "5m"
        case .thirtyMinutes: return "30m"
        case .oneHour: return "1h"
        case .twelveHours: return "12h"
        case .twentyFourHours: return "24h"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twelveHours: return 12 * 60 * 60
        case .twentyFourHours: return 24 * 60 * 60
        }
    }

    /// Soft cap so Charts stays responsive on longer windows.
    var maxChartPoints: Int {
        switch self {
        case .oneMinute: return 120
        case .fiveMinutes: return 180
        case .thirtyMinutes: return 240
        case .oneHour: return 300
        case .twelveHours: return 360
        case .twentyFourHours: return 480
        }
    }
}

enum HistoryDownsampler {
    static func downsample(_ samples: [MetricsSample], maxPoints: Int) -> [MetricsSample] {
        guard samples.count > maxPoints, maxPoints > 1 else { return samples }

        let bucketSize = Double(samples.count) / Double(maxPoints)
        var result: [MetricsSample] = []
        result.reserveCapacity(maxPoints)

        var index = 0.0
        while result.count < maxPoints && Int(index) < samples.count {
            let start = Int(index)
            let end = min(samples.count, Int(index + bucketSize))
            let slice = samples[start..<end]
            guard !slice.isEmpty else { break }

            let gpu = slice.map(\.gpuUtilizationPercent).reduce(0, +) / Double(slice.count)
            let used = slice.map(\.memoryUsedMB).reduce(0, +) / Double(slice.count)
            let total = slice.map(\.memoryTotalMB).reduce(0, +) / Double(slice.count)
            let timestamp = slice[slice.index(slice.startIndex, offsetBy: slice.count / 2)].timestamp
            result.append(
                MetricsSample(
                    timestamp: timestamp,
                    gpuUtilizationPercent: gpu,
                    memoryUsedMB: used,
                    memoryTotalMB: total
                )
            )
            index += bucketSize
        }

        return result
    }
}
