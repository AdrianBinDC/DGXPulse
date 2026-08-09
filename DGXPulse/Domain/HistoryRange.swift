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

    /// Fixed wall-clock bucket width so older points stay put as new samples arrive.
    var bucketDuration: TimeInterval {
        switch self {
        case .oneMinute: return 1
        case .fiveMinutes: return 2
        case .thirtyMinutes: return 8
        case .oneHour: return 12
        case .twelveHours: return 120
        case .twentyFourHours: return 180
        }
    }
}

enum HistoryDownsampler {
    /// Averages samples into absolute time buckets. Completed buckets are stable;
    /// only the current open bucket moves as new telemetry arrives.
    static func downsample(
        _ samples: [MetricsSample],
        range: HistoryRange,
        now: Date = .now
    ) -> [MetricsSample] {
        guard !samples.isEmpty else { return [] }

        let bucket = max(range.bucketDuration, 0.001)
        let windowStart = now.addingTimeInterval(-range.duration)
        var buckets: [Int: BucketAccumulator] = [:]

        for sample in samples where sample.timestamp >= windowStart {
            let index = Int(floor(sample.timestamp.timeIntervalSince1970 / bucket))
            var accumulator = buckets[index] ?? BucketAccumulator(index: index, bucketDuration: bucket)
            accumulator.add(sample)
            buckets[index] = accumulator
        }

        return buckets.keys.sorted().compactMap { buckets[$0]?.averagedSample }
    }
}

private struct BucketAccumulator {
    let index: Int
    let bucketDuration: TimeInterval
    private var count = 0
    private var gpu = 0.0
    private var used = 0.0
    private var total = 0.0

    init(index: Int, bucketDuration: TimeInterval) {
        self.index = index
        self.bucketDuration = bucketDuration
    }

    mutating func add(_ sample: MetricsSample) {
        count += 1
        gpu += sample.gpuUtilizationPercent
        used += sample.memoryUsedMB
        total += sample.memoryTotalMB
    }

    var averagedSample: MetricsSample? {
        guard count > 0 else { return nil }
        let midpoint = (Double(index) + 0.5) * bucketDuration
        return MetricsSample(
            timestamp: Date(timeIntervalSince1970: midpoint),
            gpuUtilizationPercent: gpu / Double(count),
            memoryUsedMB: used / Double(count),
            memoryTotalMB: total / Double(count)
        )
    }
}
