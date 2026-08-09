import Foundation
import SwiftData

@Model
final class TelemetrySampleRecord {
    var timestamp: Date
    var gpuUtilizationPercent: Double
    var memoryUsedMB: Double
    var memoryTotalMB: Double

    init(
        timestamp: Date,
        gpuUtilizationPercent: Double,
        memoryUsedMB: Double,
        memoryTotalMB: Double
    ) {
        self.timestamp = timestamp
        self.gpuUtilizationPercent = gpuUtilizationPercent
        self.memoryUsedMB = memoryUsedMB
        self.memoryTotalMB = memoryTotalMB
    }

    convenience init(sample: MetricsSample) {
        self.init(
            timestamp: sample.timestamp,
            gpuUtilizationPercent: sample.gpuUtilizationPercent,
            memoryUsedMB: sample.memoryUsedMB,
            memoryTotalMB: sample.memoryTotalMB
        )
    }

    var asSample: MetricsSample {
        MetricsSample(
            timestamp: timestamp,
            gpuUtilizationPercent: gpuUtilizationPercent,
            memoryUsedMB: memoryUsedMB,
            memoryTotalMB: memoryTotalMB
        )
    }
}

final class SwiftDataMetricsHistoryStore: MetricsHistoryStoring, @unchecked Sendable {
    private let modelContainer: ModelContainer
    private let logger: any Logging

    init(modelContainer: ModelContainer, logger: any Logging) {
        self.modelContainer = modelContainer
        self.logger = logger
    }

    func append(_ sample: MetricsSample) async throws {
        let context = ModelContext(modelContainer)
        context.insert(TelemetrySampleRecord(sample: sample))
        try context.save()
    }

    func recent(since date: Date) async throws -> [MetricsSample] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<TelemetrySampleRecord>(
            predicate: #Predicate { $0.timestamp >= date },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return try context.fetch(descriptor).map(\.asSample)
    }

    func prune(olderThan date: Date) async throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<TelemetrySampleRecord>(
            predicate: #Predicate { $0.timestamp < date }
        )
        let stale = try context.fetch(descriptor)
        for record in stale {
            context.delete(record)
        }
        if !stale.isEmpty {
            try context.save()
            logger.debug("Pruned \(stale.count) history samples", category: .history)
        }
    }
}

actor InMemoryMetricsHistoryStore: MetricsHistoryStoring {
    private var samples: [MetricsSample] = []

    func append(_ sample: MetricsSample) async throws {
        samples.append(sample)
    }

    func recent(since date: Date) async throws -> [MetricsSample] {
        samples.filter { $0.timestamp >= date }.sorted { $0.timestamp < $1.timestamp }
    }

    func prune(olderThan date: Date) async throws {
        samples.removeAll { $0.timestamp < date }
    }
}
