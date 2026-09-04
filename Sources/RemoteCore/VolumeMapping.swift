import Foundation
import RMEControl

public struct KnobVolumeMapper: Sendable {
    private let tenthsPerDetent: Int
    private var lastPosition: Int32?
    private var accumulatedTenths: Int?

    public init(tenthsPerDetent: Int = 5) {
        precondition(tenthsPerDetent > 0)
        self.tenthsPerDetent = tenthsPerDetent
    }

    public mutating func resetBaseline() {
        lastPosition = nil
    }

    public mutating func replaceAuthoritativeVolume(_ dbTenths: Int16) {
        accumulatedTenths = Int(dbTenths)
    }

    public mutating func consume(
        position: Int32,
        authoritativeDBTenths: Int16,
        maximumDBTenths: Int16
    ) -> Int16? {
        guard let previousPosition = lastPosition else {
            lastPosition = position
            accumulatedTenths = Int(authoritativeDBTenths)
            return nil
        }
        lastPosition = position
        let delta = Int64(position) - Int64(previousPosition)
        guard delta != 0 else { return nil }
        let current = Int64(accumulatedTenths ?? Int(authoritativeDBTenths))
        let next = min(
            max(current + delta * Int64(tenthsPerDetent), Int64(RMERegisterMap.minimumDBTenths)),
            Int64(maximumDBTenths)
        )
        accumulatedTenths = Int(next)
        let stepped = Int16(next)
        return stepped == authoritativeDBTenths ? nil : stepped
    }
}

/// Keeps at most one unsent target per output while preserving the value that
/// is currently being written. New knob samples replace older unsent samples.
struct VolumeWriteCoalescer: Sendable {
    private var pending: [OutputRole: Int16] = [:]
    private var inFlight: [OutputRole: Int16] = [:]

    var isEmpty: Bool { pending.isEmpty && inFlight.isEmpty }

    func isBusy(_ role: OutputRole) -> Bool {
        pending[role] != nil || inFlight[role] != nil
    }

    mutating func enqueue(_ value: Int16, for role: OutputRole) -> Bool {
        if inFlight[role] == value {
            // The knob returned to the value already being committed. Any
            // different unsent target is now stale and must not run afterward.
            pending.removeValue(forKey: role)
            return false
        }
        guard pending[role] != value else { return false }
        pending[role] = value
        return true
    }

    mutating func beginNext() -> (role: OutputRole, value: Int16)? {
        guard let request = pending.first else { return nil }
        pending.removeValue(forKey: request.key)
        inFlight[request.key] = request.value
        return (request.key, request.value)
    }

    mutating func finish(_ role: OutputRole) {
        inFlight.removeValue(forKey: role)
    }

    mutating func discardPending(_ role: OutputRole) {
        pending.removeValue(forKey: role)
    }

    mutating func removeAll() {
        pending.removeAll()
        inFlight.removeAll()
    }
}
