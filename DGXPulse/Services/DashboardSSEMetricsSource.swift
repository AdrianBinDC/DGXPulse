import Foundation

struct DashboardSSEMetricsSource: MetricsSource {
    private let http: any HTTPClient
    private let logger: any Logging
    private let clock: any Clock

    init(http: any HTTPClient, logger: any Logging, clock: any Clock) {
        self.http = http
        self.logger = logger
        self.clock = clock
    }

    func events(token: String, baseURL: URL) -> AsyncStream<MetricsEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(
                        url: baseURL.appending(path: "api/v1/gpu_telemetry/stream")
                    )
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 60

                    logger.debug("Opening telemetry stream", category: .telemetry)
                    let (bytes, response) = try await http.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.yield(.failure(.server("Invalid telemetry response.")))
                        continuation.finish()
                        return
                    }

                    if httpResponse.statusCode == 401 {
                        continuation.yield(.failure(.unauthorized))
                        continuation.finish()
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        continuation.yield(
                            .failure(.server("Unable to open telemetry stream (HTTP \(httpResponse.statusCode))."))
                        )
                        continuation.finish()
                        return
                    }

                    continuation.yield(.connected)
                    try await Self.consume(
                        bytes: bytes,
                        clock: clock,
                        logger: logger,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failure(.cancelled))
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

    private static func consume(
        bytes: URLSession.AsyncBytes,
        clock: any Clock,
        logger: any Logging,
        continuation: AsyncStream<MetricsEvent>.Continuation
    ) async throws {
        var eventName = ""
        var dataLines: [String] = []
        var lineBuffer: [UInt8] = []
        var previousWasCR = false

        for try await byte in bytes {
            try Task.checkCancellation()

            if byte == 0x0D {
                let line = decodeLine(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                previousWasCR = true
                try handleLine(
                    line,
                    eventName: &eventName,
                    dataLines: &dataLines,
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
                    let sample = try TelemetryParser.parseSample(from: data, at: clock.now())
                    continuation.yield(.sample(sample))
                } catch {
                    logger.error("Malformed telemetry payload", category: .telemetry)
                    continuation.yield(.failure(.malformedTelemetry))
                }
            case "error":
                if let body = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                    continuation.yield(.failure(.server(body.error)))
                } else {
                    continuation.yield(.failure(.server("Telemetry stream error.")))
                }
            default:
                logger.debug("Ignoring SSE event '\(eventName)'", category: .telemetry)
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
}
