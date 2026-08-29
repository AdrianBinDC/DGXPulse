import Foundation

nonisolated struct MetricsSample: Equatable, Sendable {
    var timestamp: Date
    var gpuUtilizationPercent: Double
    /// Mebibytes. Dashboard KiB fields are divided by 1024; legacy `*_in_mb` values were already MiB.
    var memoryUsedMB: Double
    var memoryTotalMB: Double

    /// Decimal gigabytes — same as DGX Dashboard `GB` (`KiB * 1024 / 1e9`).
    var memoryUsedGB: Double { Self.decimalGigabytes(fromMebibytes: memoryUsedMB) }

    var memoryTotalGB: Double { Self.decimalGigabytes(fromMebibytes: memoryTotalMB) }

    var memoryUsedGiB: Double { memoryUsedMB / 1_024 }

    var memoryTotalGiB: Double { memoryTotalMB / 1_024 }

    var memoryUtilizationPercent: Double {
        guard memoryTotalMB > 0 else { return 0 }
        return (memoryUsedMB / memoryTotalMB) * 100
    }

    /// `mebibytes * 1024 * 1024 / 1_000_000_000`, matching dashboard `GB`.
    nonisolated static func decimalGigabytes(fromMebibytes mebibytes: Double) -> Double {
        mebibytes * 1_048_576 / 1_000_000_000
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

nonisolated enum TelemetryMemoryFields: String, Sendable {
    case kibibytes = "memory_*_in_kib"
    case megabytes = "memory_*_in_mb"
}

nonisolated struct ParsedTelemetry: Sendable {
    var sample: MetricsSample
    var memoryFields: TelemetryMemoryFields
}

nonisolated struct DashboardGPUTelemetry: Decodable, Sendable {
    let percentageUtilization: Double
    let memoryTotalInMB: Double
    let memoryAvailableInMB: Double
    let memoryFields: TelemetryMemoryFields

    nonisolated enum CodingKeys: String, CodingKey {
        case percentageUtilization = "percentage_utilization"
        case memoryTotalInMB = "memory_total_in_mb"
        case memoryAvailableInMB = "memory_available_in_mb"
        case memoryTotalInKiB = "memory_total_in_kib"
        case memoryAvailableInKiB = "memory_available_in_kib"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percentageUtilization = try container.decode(Double.self, forKey: .percentageUtilization)
        // Current DGX Dashboard reports system memory in KiB. Older builds used
        // `*_in_mb` (values were MiB). Normalize to MiB for MetricsSample.
        if let totalKiB = try container.decodeIfPresent(Double.self, forKey: .memoryTotalInKiB),
            let availableKiB = try container.decodeIfPresent(Double.self, forKey: .memoryAvailableInKiB)
        {
            memoryTotalInMB = totalKiB / 1_024
            memoryAvailableInMB = availableKiB / 1_024
            memoryFields = .kibibytes
        } else {
            memoryTotalInMB = try container.decode(Double.self, forKey: .memoryTotalInMB)
            memoryAvailableInMB = try container.decode(Double.self, forKey: .memoryAvailableInMB)
            memoryFields = .megabytes
        }
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
    nonisolated static func parse(_ data: Data, at date: Date) throws -> ParsedTelemetry {
        let payload = try JSONDecoder().decode(DashboardTelemetryPayload.self, from: data)
        guard let gpu = payload.telemetryForGPUs.first else {
            throw ConnectionFailure.malformedTelemetry
        }
        return ParsedTelemetry(sample: gpu.asMetricsSample(at: date), memoryFields: gpu.memoryFields)
    }

    nonisolated static func parseSample(from data: Data, at date: Date) throws -> MetricsSample {
        try parse(data, at: date).sample
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
