import Foundation

/// All calls are serialized by UCXIIController, including response ACKs.
protocol UCXIIDSPTransport: AnyObject, Sendable {
    func identify() throws -> UCXIIDeviceIdentity
    func writeDSP(_ words: [UInt32]) throws
    func triggerDSPRead() throws
    func readDSP() throws -> [UInt32]
}

struct UCXIIDeviceIdentity: Sendable {
    static let vendor: UInt64 = 0x2a39
    static let product: UInt64 = 0x3f82
    let serial: UInt64
    let product: UInt64

    func validate(expectedSerial: UInt64) throws {
        guard serial == expectedSerial, product == Self.product else {
            throw RMEControlError.deviceIdentityMismatch(serial: serial, product: product)
        }
    }
}

/// The only DriverKit write payload this remote can send. In particular, input
/// mute metadata, submix faders/pans and routing coefficients are never writable.
struct UCXIIDSPWrite {
    let wordCount: UInt64
    let staging: [UInt32]

    init(_ words: [UInt32]) throws {
        guard (1...128).contains(words.count) else {
            throw RMEControlError.invalidWriteCount(words.count)
        }
        for word in words {
            let (register, value) = RMEWordCodec.decode(word)
            let allowed: Bool
            switch register {
            case RMERegisterMap.micLine1Gain:
                allowed = (RMERegisterMap.minimumMicGainDBTenths...RMERegisterMap.maximumMicGainDBTenths).contains(value)
            case RMERegisterMap.poll:
                allowed = (0..<16).contains(value)
            case RMERegisterMap.refresh:
                allowed = value == RMERegisterMap.refreshValue
            default:
                allowed = RMERegisterMap.outputVolumeRegisters.contains(register)
                    && (RMERegisterMap.minimumDBTenths...RMERegisterMap.maximumHardwareDBTenths).contains(value)
            }
            guard allowed, !word.nonzeroBitCount.isMultiple(of: 2) else {
                throw RMEControlError.unsafeDSPWrite(register)
            }
        }
        wordCount = UInt64(words.count)
        staging = words + Array(repeating: 0, count: 128 - words.count)
    }
}
