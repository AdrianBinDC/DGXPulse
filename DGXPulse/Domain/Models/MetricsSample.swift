import Foundation

struct MetricsSample: Equatable, Sendable {
    var timestamp: Date
    var gpuUtilizationPercent: Double
    var memoryUsedMB: Double
    var memoryTotalMB: Double

    /// Matches DGX Dashboard's used-memory conversion (`MB / 1000`).
    var memoryUsedGB: Double { memoryUsedMB / 1_000 }

    /// Dashboard fields are MiB; divide by 1024 so 128 GiB systems show 128 GB total.
    var memoryTotalGB: Double { memoryTotalMB / 1_024 }

    var memoryUtilizationPercent: Double {
        guard memoryTotalMB > 0 else { return 0 }
        return (memoryUsedMB / memoryTotalMB) * 100
    }
}

struct DashboardTelemetryPayload: Decodable, Sendable {
    let telemetryForGPUs: [DashboardGPUTelemetry]

    enum CodingKeys: String, CodingKey {
        case telemetryForGPUs = "TelemetryForGPUs"
    }
}

struct DashboardGPUTelemetry: Decodable, Sendable {
    let percentageUtilization: Double
    let memoryTotalInMB: Double
    let memoryAvailableInMB: Double

    enum CodingKeys: String, CodingKey {
        case percentageUtilization = "percentage_utilization"
        case memoryTotalInMB = "memory_total_in_mb"
        case memoryAvailableInMB = "memory_available_in_mb"
    }

    func asMetricsSample(at date: Date) -> MetricsSample {
        MetricsSample(
            timestamp: date,
            gpuUtilizationPercent: percentageUtilization,
            memoryUsedMB: max(0, memoryTotalInMB - memoryAvailableInMB),
            memoryTotalMB: memoryTotalInMB
        )
    }
}

enum TelemetryParser {
    static func parseSample(from data: Data, at date: Date = .now) throws -> MetricsSample {
        let payload = try JSONDecoder().decode(DashboardTelemetryPayload.self, from: data)
        guard let gpu = payload.telemetryForGPUs.first else {
            throw ConnectionFailure.malformedTelemetry
        }
        return gpu.asMetricsSample(at: date)
    }
}

struct LoginResponse: Decodable, Sendable {
    let token: String
}

struct DashboardErrorResponse: Decodable, Sendable {
    let error: String
}
