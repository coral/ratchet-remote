import Foundation

/// Revokes existing driver sessions synchronously when TotalMix starts. The UI
/// never waits for a snapshot or for the controller actor to process the handoff.
public final class RMEAccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var totalMixRunning = false

    public init() {}

    public func setTotalMixRunning(_ running: Bool) {
        lock.withLock {
            guard running != totalMixRunning else { return }
            totalMixRunning = running
            generation &+= 1
        }
    }

    func invalidate() {
        lock.withLock { generation &+= 1 }
    }

    func session() -> UInt64 {
        lock.withLock { generation }
    }

    func validate(_ session: UInt64) throws {
        try lock.withLock {
            guard !totalMixRunning else { throw RMEControlError.totalMixActive }
            guard generation == session else { throw RMEControlError.notConnected }
        }
    }
}

/// Check before every I/O, including reads and ACKs using a transport retained
/// across an actor suspension. Resuming access never revives an old session.
final class GatedDSPTransport: UCXIIDSPTransport {
    private let base: any UCXIIDSPTransport
    private let access: RMEAccessGate
    private let session: UInt64

    init(_ base: any UCXIIDSPTransport, access: RMEAccessGate, session: UInt64) {
        self.base = base
        self.access = access
        self.session = session
    }

    func identify() throws -> UCXIIDeviceIdentity {
        try access.validate(session)
        return try base.identify()
    }

    func writeDSP(_ words: [UInt32]) throws {
        try access.validate(session)
        try base.writeDSP(words)
    }

    func triggerDSPRead() throws {
        try access.validate(session)
        try base.triggerDSPRead()
    }

    func readDSP() throws -> [UInt32] {
        try access.validate(session)
        return try base.readDSP()
    }
}
