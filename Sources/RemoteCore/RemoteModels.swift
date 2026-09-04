import Foundation
import RatchetProtocol
import RMEControl

public enum RatchetCompatibilityError: Error, LocalizedError, Sendable {
    case missingCapabilities
    case unsupportedCapabilities(String)

    public var errorDescription: String? {
        switch self {
        case .missingCapabilities:
            "Ratchet Hello did not include hardware capabilities"
        case .unsupportedCapabilities(let detail):
            "Ratchet hardware is not compatible: \(detail)"
        }
    }
}

public enum OutputRole: String, CaseIterable, Codable, Sendable {
    case main
    case phones

    public var label: String { rawValue.uppercased() }
    public var rmeOutput: RMEOutput { self == .main ? .main : .phones }
    public var maximumDBTenths: Int16 { rmeOutput.maximumDBTenths }

    public var alternate: OutputRole { self == .main ? .phones : .main }
}

public enum RatchetInputActivity {
    public static func shouldWake(for input: Ratchet_V1_InputEvent) -> Bool {
        switch input.input {
        case .button:
            true
        case .knob(let knob):
            // Regular-mode telemetry also arrives for sub-detent angle noise.
            // Only a crossed detent is deliberate enough to reset idle dimming.
            knob.delta != 0
        case .none:
            false
        }
    }
}

public struct RemoteViewState: Equatable, Sendable {
    public var selectedRole: OutputRole
    public var ratchetConnected: Bool
    public var ratchetConfigured: Bool
    public var ratchetSerial: String?
    public var rmeConnected: Bool
    public var rmeState: UCXIIState?
    public var mutedRestoreVolumes: [RMEOutput: Int16]
    public var ratchetError: String?
    public var rmeError: String?

    public init(selectedRole: OutputRole = .main) {
        self.selectedRole = selectedRole
        ratchetConnected = false
        ratchetConfigured = false
        ratchetSerial = nil
        rmeConnected = false
        rmeState = nil
        mutedRestoreVolumes = [:]
        ratchetError = nil
        rmeError = nil
    }

    public var selectedOutput: StereoOutputState? {
        rmeState?[selectedRole.rmeOutput]
    }

    public var errorMessage: String? { ratchetError ?? rmeError }

    public var selectedOutputMuted: Bool {
        selectedOutput?.muted == true
    }

    public var volumeText: String {
        guard let selectedOutput else { return "—" }
        if selectedOutput.muted { return "MUTED" }
        return String(format: "%.1f", Double(selectedOutput.dbTenths) / 10.0)
    }

    public var statusSummary: String {
        switch (ratchetConnected, ratchetConfigured, rmeConnected) {
        case (true, true, true): "Connected"
        case (true, false, _): "Configuring Ratchet"
        case (false, _, true): "Ratchet offline"
        case (true, true, false): "RME offline"
        case (false, _, false): "Waiting for devices"
        }
    }
}

public extension Ratchet_V1_Hello {
    /// Ratchet Remote currently composes frames for the fixed H1 layout and
    /// switches between disabled and regular haptics at runtime.
    func validateForRemote() throws {
        guard hasCapabilities else { throw RatchetCompatibilityError.missingCapabilities }
        let capabilities = capabilities
        var mismatches: [String] = []
        if capabilities.ringLedCount != 60 { mismatches.append("expected 60 ring LEDs, found \(capabilities.ringLedCount)") }
        if capabilities.keyLedCount != 8 { mismatches.append("expected 8 key LEDs, found \(capabilities.keyLedCount)") }
        if capabilities.buttonCount != 4 { mismatches.append("expected 4 buttons, found \(capabilities.buttonCount)") }
        if capabilities.displayWidth != 240 || capabilities.displayHeight != 240 {
            mismatches.append("expected a 240x240 display, found \(capabilities.displayWidth)x\(capabilities.displayHeight)")
        }
        if capabilities.maxMessageBytes < UInt32(HIDFraming.maximumMessageSize) {
            mismatches.append("maximum message size is \(capabilities.maxMessageBytes), expected at least \(HIDFraming.maximumMessageSize)")
        }
        if !capabilities.hapticModes.contains(.disabled) { mismatches.append("disabled haptics are unavailable") }
        if !capabilities.hapticModes.contains(.regular) { mismatches.append("regular haptics are unavailable") }
        guard mismatches.isEmpty else {
            throw RatchetCompatibilityError.unsupportedCapabilities(mismatches.joined(separator: "; "))
        }
    }
}
