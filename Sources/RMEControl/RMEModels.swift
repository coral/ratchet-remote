import Foundation

public enum RMEOutput: String, CaseIterable, Sendable {
    case main
    case phones

    public var label: String {
        switch self {
        case .main: "Main 1/2"
        case .phones: "Phones 7/8"
        }
    }

    public var maximumDBTenths: Int16 {
        switch self {
        case .main: 0
        case .phones: -150
        }
    }
}

public struct StereoOutputState: Equatable, Sendable {
    public var leftDBTenths: Int16
    public var rightDBTenths: Int16

    public init(
        leftDBTenths: Int16,
        rightDBTenths: Int16
    ) {
        self.leftDBTenths = leftDBTenths
        self.rightDBTenths = rightDBTenths
    }

    /// The quieter channel is the safe representative value if a stereo pair is unlinked.
    public var dbTenths: Int16 { min(leftDBTenths, rightDBTenths) }
    public var isAtFloor: Bool { dbTenths <= RMERegisterMap.minimumDBTenths }
    /// Output mute is implemented as a reversible write to the RME volume floor.
    public var muted: Bool { isAtFloor }
    public var hasLevelMismatch: Bool { leftDBTenths != rightDBTenths }
}

public struct UCXIIState: Equatable, Sendable {
    public var serial: UInt64
    public var micLine1GainDBTenths: Int16
    public var main: StereoOutputState
    public var phones: StereoOutputState

    public init(
        serial: UInt64,
        micLine1GainDBTenths: Int16,
        main: StereoOutputState,
        phones: StereoOutputState
    ) {
        self.serial = serial
        self.micLine1GainDBTenths = micLine1GainDBTenths
        self.main = main
        self.phones = phones
    }

    /// The UCX II has no digital mute here; zero preamp gain is the practical
    /// mute for the attached low-output microphone.
    public var micLine1Muted: Bool {
        micLine1GainDBTenths <= RMERegisterMap.minimumMicGainDBTenths
    }

    public subscript(output: RMEOutput) -> StereoOutputState {
        switch output {
        case .main: main
        case .phones: phones
        }
    }
}

public enum RMEControlError: Error, LocalizedError, Sendable {
    case noDevice(serial: UInt64?)
    case multipleDevices
    case malformedDeviceUID(String)
    case missingRegistryProperty(String)
    case io(operation: String, status: Int32)
    case invalidWriteCount(Int)
    case invalidReadSize(Int)
    case snapshotTimedOut(missingRegisters: [UInt16])
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .noDevice(let serial):
            serial.map { "no Fireface UCX II with serial \($0) found" } ?? "no Fireface UCX II found"
        case .multipleDevices: "multiple Fireface UCX II devices found; choose a serial number"
        case .malformedDeviceUID(let uid): "unexpected RME device UID: \(uid)"
        case .missingRegistryProperty(let property): "RME service has no \(property) property"
        case .io(let operation, let status): "\(operation) failed with IOKit status 0x\(String(UInt32(bitPattern: status), radix: 16))"
        case .invalidWriteCount(let count): "a DSP write must contain 1 to 128 words (received \(count))"
        case .invalidReadSize(let size): "the RME driver returned an invalid DSP payload size: \(size)"
        case .snapshotTimedOut(let registers):
            "timed out reading UCX II state; missing " + registers.map { String(format: "0x%04x", $0) }.joined(separator: ", ")
        case .notConnected: "the Fireface UCX II is not connected"
        }
    }
}
