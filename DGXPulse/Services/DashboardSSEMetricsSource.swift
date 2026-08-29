import Foundation

nonisolated struct DashboardSSEMetricsSource: MetricsSource {
    private let http: any HTTPClient
    private let logger: any Logging
    private let clock: any Clock
    private let idleTimeout: Duration

    init(
        http: any HTTPClient,
        logger: any Logging,
        clock: any Clock,
        idleTimeout: Duration = DashboardPorts.telemetryIdleTimeout
    ) {
        self.http = http
        self.logger = logger
        self.clock = clock
        self.idleTimeout = idleTimeout
    }

    nonisolated func events(token: String, baseURL: URL) -> AsyncStream<MetricsEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(
                        url: baseURL.appending(path: "api/v1/gpu_telemetry/stream")
                    )
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Prefer session-level request timeout; keep request timeout generous.
                    request.timeoutInterval = 60

                    let streamURL = request.url?.absoluteString ?? "api/v1/gpu_telemetry/stream"
                    logger.info("Opening telemetry stream \(streamURL)", category: .telemetry)
                    let (bytes, response) = try await http.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        logger.error("Telemetry stream returned a non-HTTP response", category: .telemetry)
                        continuation.yield(.failure(.server("Invalid telemetry response.")))
                        continuation.finish()
                        return
                    }

                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "none"
                    logger.info(
                        "Telemetry stream HTTP \(httpResponse.statusCode) Content-Type=\(contentType)",
                        category: .telemetry
                    )

                    if httpResponse.statusCode == 401 {
                        logger.error("Telemetry stream unauthorized", category: .telemetry)
                        continuation.yield(.failure(.unauthorized))
                        continuation.finish()
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        logger.error(
                            "Unable to open telemetry stream (HTTP \(httpResponse.statusCode))",
                            category: .telemetry
                        )
                        continuation.yield(
                            .failure(
                                .server(
                                    "Unable to open telemetry stream (HTTP \(httpResponse.statusCode))."
                                )
                            )
                        )
                        continuation.finish()
                        return
                    }

                    continuation.yield(.connected)
                    try await Self.consumeWithIdleWatchdog(
                        bytes: bytes,
                        clock: clock,
                        idleTimeout: idleTimeout,
                        logger: logger,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failure(.cancelled))
                    continuation.finish()
                } catch let failure as ConnectionFailure {
                    continuation.yield(.failure(failure))
                    continuation.finish()
                } catch {
                    let failure = (error as? ConnectionFailure) ?? .unreachable(baseURL.absoluteString)
                    continuation.yield(.failure(failure))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func consumeWithIdleWatchdog(
        bytes: URLSession.AsyncBytes,
        clock: any Clock,
        idleTimeout: Duration,
        logger: any Logging,
        continuation: AsyncStream<MetricsEvent>.Continuation
    ) async throws {
        let activity = StreamActivityClock(clock: clock)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Self.consume(
                    bytes: bytes,
                    activity: activity,
                    clock: clock,
                    logger: logger,
                    continuation: continuation
                )
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    if await activity.isIdle(longerThan: idleTimeout) {
                        logger.error(
                            "Telemetry stream idle for \(idleTimeout); reconnecting",
                            category: .telemetry
                        )
                        throw ConnectionFailure.tunnelUnavailable
                    }
                }
            }

            // First failure/completion cancels the peer (idle watchdog or stream end).
            _ = try await group.next()
            group.cancelAll()
            do {
                try await group.waitForAll()
            } catch is CancellationError {
                // Expected when the sibling is cancelled after stream end / idle timeout.
            }
        }
    }

    private static func consume(
        bytes: URLSession.AsyncBytes,
        activity: StreamActivityClock,
        clock: any Clock,
        logger: any Logging,
        continuation: AsyncStream<MetricsEvent>.Continuation
    ) async throws {
        var eventName = ""
        var dataLines: [String] = []
        var lineBuffer: [UInt8] = []
        var previousWasCR = false
        let stats = TelemetryStreamStats(now: clock.now())
        defer {
            logger.info(
                "Telemetry stream closed samples=\(stats.acceptedSamples) "
                    + "malformed=\(stats.malformedEvents) ignored=\(stats.ignoredEvents)",
                category: .telemetry
            )
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            await activity.touch()

            if byte == 0x0D {
                let line = decodeLine(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                previousWasCR = true
                try handleLine(
                    line,
                    eventName: &eventName,
                    dataLines: &dataLines,
                    stats: stats,
                    clock: clock,
                    logger: logger,
                    continuation: continuation
                )
            } else if byte == 0x0A {
                if previousWasCR {
                    previousWasCR = false
                    continue
                }
                let line = decodeLine(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                try handleLine(
                    line,
                    eventName: &eventName,
                    dataLines: &dataLines,
                    stats: stats,
                    clock: clock,
                    logger: logger,
                    continuation: continuation
                )
            } else {
                previousWasCR = false
                lineBuffer.append(byte)
            }
        }
    }

    private static func handleLine(
        _ line: String,
        eventName: inout String,
        dataLines: inout [String],
        stats: TelemetryStreamStats,
        clock: any Clock,
        logger: any Logging,
        continuation: AsyncStream<MetricsEvent>.Continuation
    ) throws {
        if line.isEmpty {
            guard !dataLines.isEmpty else {
                eventName = ""
                return
            }
            let data = Data(dataLines.joined(separator: "\n").utf8)
            switch eventName {
            case "gpu_telemetry", "":
                do {
                    let parsed = try TelemetryParser.parse(data, at: clock.now())
                    stats.acceptedSamples += 1
                    logAcceptedSample(parsed, stats: stats, clock: clock, logger: logger)
                    continuation.yield(.sample(parsed.sample))
                } catch {
                    stats.malformedEvents += 1
                    logMalformedPayload(data, error: error, stats: stats, logger: logger)
                    continuation.yield(.failure(.malformedTelemetry))
                }
            case "error":
                logger.error(
                    "Telemetry SSE error event \(JSONDiagnostics.summarize(data))",
                    category: .telemetry
                )
                if let body = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                    continuation.yield(.failure(.server(body.error)))
                } else {
                    continuation.yield(.failure(.server("Telemetry stream error.")))
                }
            default:
                stats.ignoredEvents += 1
                if stats.seenIgnoredEventNames.insert(eventName).inserted {
                    logger.info(
                        "Ignoring SSE event '\(eventName)' \(JSONDiagnostics.summarize(data))",
                        category: .telemetry
                    )
                } else {
                    logger.debug("Ignoring SSE event '\(eventName)'", category: .telemetry)
                }
            }
            eventName = ""
            dataLines.removeAll(keepingCapacity: true)
            return
        }

        if line.hasPrefix(":") { return }

        if let separator = line.firstIndex(of: ":") {
            let field = String(line[..<separator])
            var value = String(line[line.index(after: separator)...])
            if value.first == " " { value.removeFirst() }
            switch field {
            case "event":
                eventName = value
            case "data":
                dataLines.append(value)
            default:
                break
            }
        }
    }

    private static func decodeLine(_ bytes: [UInt8]) -> String {
        var bytes = bytes
        if bytes.last == 0x0D { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func logAcceptedSample(
        _ parsed: ParsedTelemetry,
        stats: TelemetryStreamStats,
        clock: any Clock,
        logger: any Logging
    ) {
        let sample = parsed.sample
        let gpu = Int(sample.gpuUtilizationPercent.rounded())
        let ram = Int(sample.memoryUtilizationPercent.rounded())
        if !stats.loggedFirstSample {
            stats.loggedFirstSample = true
            logger.info(
                "First telemetry sample fields=\(parsed.memoryFields.rawValue) "
                    + "gpu=\(gpu)% ram=\(ram)% "
                    + "usedMB=\(Int(sample.memoryUsedMB.rounded())) "
                    + "totalMB=\(Int(sample.memoryTotalMB.rounded()))",
                category: .telemetry
            )
            stats.lastHeartbeat = clock.now()
            return
        }
        let now = clock.now()
        guard now.timeIntervalSince(stats.lastHeartbeat) >= DashboardPorts.telemetryHeartbeatInterval
        else { return }
        stats.lastHeartbeat = now
        logger.info(
            "Telemetry heartbeat gpu=\(gpu)% ram=\(ram)% samples=\(stats.acceptedSamples)",
            category: .telemetry
        )
    }

    private static func logMalformedPayload(
        _ data: Data,
        error: Error,
        stats: TelemetryStreamStats,
        logger: any Logging
    ) {
        if !stats.loggedFirstMalformed {
            stats.loggedFirstMalformed = true
            logger.error(
                "Malformed telemetry: \(JSONDiagnostics.describe(error)) \(JSONDiagnostics.summarize(data))",
                category: .telemetry
            )
            return
        }
        if stats.malformedEvents.isMultiple(of: 25) {
            logger.error(
                "Skipped \(stats.malformedEvents) malformed telemetry events",
                category: .telemetry
            )
        }
    }
}

private final class TelemetryStreamStats: @unchecked Sendable {
    var acceptedSamples = 0
    var malformedEvents = 0
    var ignoredEvents = 0
    var loggedFirstSample = false
    var loggedFirstMalformed = false
    var seenIgnoredEventNames: Set<String> = []
    var lastHeartbeat: Date

    init(now: Date) {
        lastHeartbeat = now
    }
}

private actor StreamActivityClock {
    private let clock: any Clock
    private var lastActivity: Date

    init(clock: any Clock) {
        self.clock = clock
        self.lastActivity = clock.now()
    }

    func touch() {
        lastActivity = clock.now()
    }

    func isIdle(longerThan timeout: Duration) -> Bool {
        let limit =
            TimeInterval(timeout.components.seconds)
            + TimeInterval(timeout.components.attoseconds) / 1e18
        return clock.now().timeIntervalSince(lastActivity) > limit
    }
}
