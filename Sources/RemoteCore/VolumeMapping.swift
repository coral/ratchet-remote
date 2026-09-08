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
        accumulatedTenths = nil
    }

    public mutating func replaceAuthoritativeVolume(_ dbTenths: Int16) {
        accumulatedTenths = Int(dbTenths)
    }

    public mutating func consume(
        position: Int32,
        reportedDelta: Int32,
        authoritativeDBTenths: Int16,
        maximumDBTenths: Int16
    ) -> Int16? {
        // The first event after Configure/SetHaptics establishes the new
        // logical coordinate system. The coordinator resets this mapper when
        // that transition completes, so this baseline must never change gain.
        if lastPosition == nil {
            lastPosition = position
            if accumulatedTenths == nil {
                accumulatedTenths = Int(authoritativeDBTenths)
            }
            guard reportedDelta != 0 else { return nil }

            // The ACK for SetHaptics and its zero-delta baseline travel in
            // separate device messages. If the baseline arrives while input is
            // still gated, the first usable sample may already contain several
            // crossed detents. Its reported delta is authoritative; dropping it
            // makes the audio stop short of the physical endpoint by an amount
            // that depends on the speed of that first movement.
            accumulatedTenths = Int(authoritativeDBTenths)
            return advance(
                by: Int64(reportedDelta),
                authoritativeDBTenths: authoritativeDBTenths,
                maximumDBTenths: maximumDBTenths
            )
        }

        // Position is the authoritative logical snapshot. Comparing absolute
        // positions survives coalesced USB snapshots and also keeps the client
        // compatible with older firmware that published position and delta
        // separately. If a legacy delayed delta arrives with an unchanged
        // position, the movement is still applied exactly once.
        let delta = Int64(position) - Int64(lastPosition!)
        lastPosition = position
        guard delta != 0 else { return nil }
        return advance(
            by: delta,
            authoritativeDBTenths: authoritativeDBTenths,
            maximumDBTenths: maximumDBTenths
        )
    }

    private mutating func advance(
        by delta: Int64,
        authoritativeDBTenths: Int16,
        maximumDBTenths: Int16
    ) -> Int16? {
        let current = Int64(accumulatedTenths ?? Int(authoritativeDBTenths))
        let next = min(
            max(current + delta * Int64(tenthsPerDetent), Int64(RMERegisterMap.minimumDBTenths)),
            Int64(maximumDBTenths)
        )
        // Compare against our intended value, not the asynchronously reported
        // RME value. During a fast reversal, `authoritativeDBTenths` can happen
        // to equal this new target while an older, different write is still
        // queued. Dropping the new target in that case lets the stale write win
        // and leaves the audio short of the physical haptic endpoint.
        guard next != current else { return nil }
        accumulatedTenths = Int(next)
        return Int16(next)
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
