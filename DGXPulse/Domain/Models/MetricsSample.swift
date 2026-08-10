import Foundation

nonisolated struct MetricsSample: Equatable, Sendable {
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

nonisolated struct DashboardTelemetryPayload: Decodable, Sendable {
    let telemetryForGPUs: [DashboardGPUTelemetry]

    nonisolated enum CodingKeys: String, CodingKey {
        case telemetryForGPUs = "TelemetryForGPUs"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        telemetryForGPUs = try container.decode([DashboardGPUTelemetry].self, forKey: .telemetryForGPUs)
    }
}

nonisolated struct DashboardGPUTelemetry: Decodable, Sendable {
    let percentageUtilization: Double
    let memoryTotalInMB: Double
    let memoryAvailableInMB: Double

    nonisolated enum CodingKeys: String, CodingKey {
        case percentageUtilization = "percentage_utilization"
        case memoryTotalInMB = "memory_total_in_mb"
        case memoryAvailableInMB = "memory_available_in_mb"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percentageUtilization = try container.decode(Double.self, forKey: .percentageUtilization)
        memoryTotalInMB = try container.decode(Double.self, forKey: .memoryTotalInMB)
        memoryAvailableInMB = try container.decode(Double.self, forKey: .memoryAvailableInMB)
    }

    nonisolated func asMetricsSample(at date: Date) -> MetricsSample {
        MetricsSample(
            timestamp: date,
            gpuUtilizationPercent: percentageUtilization,
            memoryUsedMB: max(0, memoryTotalInMB - memoryAvailableInMB),
            memoryTotalMB: memoryTotalInMB
        )
    }
}

nonisolated enum TelemetryParser {
    nonisolated static func parseSample(from data: Data, at date: Date) throws -> MetricsSample {
        let payload = try JSONDecoder().decode(DashboardTelemetryPayload.self, from: data)
        guard let gpu = payload.telemetryForGPUs.first else {
            throw ConnectionFailure.malformedTelemetry
        }
        return gpu.asMetricsSample(at: date)
    }
}

nonisolated struct LoginResponse: Decodable, Sendable {
    let token: String

    nonisolated enum CodingKeys: String, CodingKey {
        case token
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
    }
}

nonisolated struct DashboardErrorResponse: Decodable, Sendable {
    let error: String

    nonisolated enum CodingKeys: String, CodingKey {
        case error
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(String.self, forKey: .error)
    }
}
