import Foundation
import OSLog

enum RMETiming {
    static let log = Logger(subsystem: "com.coral.RatchetRemote", category: "RMETiming")
    static let verbose = ProcessInfo.processInfo.arguments.contains("--diagnostics")

    static func record(_ operation: String, since start: TimeInterval, detail: String = "") {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        if milliseconds >= 50 {
            log.warning("\(operation, privacy: .public) ms=\(milliseconds) \(detail, privacy: .public)")
        } else if verbose {
            log.notice("\(operation, privacy: .public) ms=\(milliseconds) \(detail, privacy: .public)")
        }
    }
}

/// Measures individual DriverKit calls separately from time spent waiting for
/// USB responses or queued behind other controller operations.
final class TimedDSPTransport: UCXIIDSPTransport, @unchecked Sendable {
    let base: any UCXIIDSPTransport
    init(_ base: any UCXIIDSPTransport) { self.base = base }

    func identify() throws -> UCXIIDeviceIdentity {
        let start = ProcessInfo.processInfo.systemUptime
        defer { RMETiming.record("driver.identity", since: start) }
        return try base.identify()
    }
    func writeDSP(_ words: [UInt32]) throws {
        let start = ProcessInfo.processInfo.systemUptime
        defer { RMETiming.record("driver.write", since: start, detail: "words=\(words.count)") }
        try base.writeDSP(words)
    }
    func triggerDSPRead() throws {
        let start = ProcessInfo.processInfo.systemUptime
        defer { RMETiming.record("driver.trigger", since: start) }
        try base.triggerDSPRead()
    }
    func readDSP() throws -> [UInt32] {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            // Empty reads are frequent; only slow driver reads need a record.
            if ProcessInfo.processInfo.systemUptime - start >= 0.020 {
                RMETiming.log.warning("driver.read ms=\((ProcessInfo.processInfo.systemUptime - start) * 1_000)")
            }
        }
        return try base.readDSP()
    }
}
