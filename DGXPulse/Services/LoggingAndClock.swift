import Foundation
import OSLog

nonisolated struct OSLogLogger: Logging {
    private let subsystem: String

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "DGXPulse") {
        self.subsystem = subsystem
    }

    nonisolated func debug(_ message: String, category: LogCategory) {
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(message, privacy: .public)")
    }

    nonisolated func info(_ message: String, category: LogCategory) {
        Logger(subsystem: subsystem, category: category.rawValue).info("\(message, privacy: .public)")
    }

    nonisolated func error(_ message: String, category: LogCategory) {
        Logger(subsystem: subsystem, category: category.rawValue).error("\(message, privacy: .public)")
    }
}

actor DiagnosticsRingBuffer {
    private var lines: [String] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func snapshot() -> [String] {
        lines
    }
}

nonisolated struct MultiplexLogger: Logging {
    private let primary: any Logging
    private let ring: DiagnosticsRingBuffer

    init(primary: any Logging, ring: DiagnosticsRingBuffer) {
        self.primary = primary
        self.ring = ring
    }

    nonisolated func debug(_ message: String, category: LogCategory) {
        primary.debug(message, category: category)
        Task { await ring.append("DEBUG [\(category.rawValue)] \(message)") }
    }

    nonisolated func info(_ message: String, category: LogCategory) {
        primary.info(message, category: category)
        Task { await ring.append("INFO [\(category.rawValue)] \(message)") }
    }

    nonisolated func error(_ message: String, category: LogCategory) {
        primary.error(message, category: category)
        Task { await ring.append("ERROR [\(category.rawValue)] \(message)") }
    }
}

nonisolated struct SystemClock: Clock {
    nonisolated func now() -> Date { Date() }
}

nonisolated struct SystemSleeper: Sleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
