import Foundation

public enum RMERegisterMap {
    public static let minimumDBTenths: Int16 = -650
    public static let maximumHardwareDBTenths: Int16 = 60
    public static let minimumMicGainDBTenths: Int16 = 0
    public static let maximumMicGainDBTenths: Int16 = 750

    public static let micLine1Gain: UInt16 = 0x0008

    public static let mainLeftVolume: UInt16 = 0x0500
    public static let mainRightVolume: UInt16 = 0x0540

    public static let phonesLeftVolume: UInt16 = 0x0680
    public static let phonesRightVolume: UInt16 = 0x06c0

    static let poll: UInt16 = 0x3dff
    static let refresh: UInt16 = 0x3e04
    static let refreshValue: Int16 = 0x67cd

    public static let stateRegisters: Set<UInt16> = [
        micLine1Gain,
        mainLeftVolume, mainRightVolume,
        phonesLeftVolume, phonesRightVolume,
    ]

    static func volumeRegisters(for output: RMEOutput) -> (UInt16, UInt16) {
        switch output {
        case .main: (mainLeftVolume, mainRightVolume)
        case .phones: (phonesLeftVolume, phonesRightVolume)
        }
    }

}

public enum RMEWordCodec {
    /// Encodes the odd parity bit used by the UCX II's DSP register stream.
    public static func encodeWrite(register: UInt16, value: Int16) -> UInt32 {
        var word = UInt32(register) << 16 | UInt32(UInt16(bitPattern: value))
        if word.nonzeroBitCount.isMultiple(of: 2) {
            word |= 1 << 31
        }
        return word
    }

    public static func decode(_ word: UInt32) -> (register: UInt16, value: Int16) {
        (
            UInt16(truncatingIfNeeded: (word >> 16) & 0x7fff),
            Int16(bitPattern: UInt16(truncatingIfNeeded: word))
        )
    }
}

struct UCXIIStateAccumulator: Sendable {
    var values: [UInt16: Int16] = [:]

    mutating func update(words: some Sequence<UInt32>) -> Bool {
        var changed = false
        for word in words {
            let decoded = RMEWordCodec.decode(word)
            guard RMERegisterMap.stateRegisters.contains(decoded.register) else { continue }
            if values[decoded.register] != decoded.value {
                values[decoded.register] = decoded.value
                changed = true
            }
        }
        return changed
    }

    mutating func set(register: UInt16, value: Int16) {
        values[register] = value
    }

    var missingRegisters: [UInt16] {
        RMERegisterMap.stateRegisters.filter { values[$0] == nil }.sorted()
    }

    func state(serial: UInt64) -> UCXIIState? {
        guard let micGain = values[RMERegisterMap.micLine1Gain],
              let mainLeft = values[RMERegisterMap.mainLeftVolume],
              let mainRight = values[RMERegisterMap.mainRightVolume],
              let phonesLeft = values[RMERegisterMap.phonesLeftVolume],
              let phonesRight = values[RMERegisterMap.phonesRightVolume] else { return nil }

        return UCXIIState(
            serial: serial,
            micLine1GainDBTenths: micGain,
            main: StereoOutputState(
                leftDBTenths: mainLeft,
                rightDBTenths: mainRight
            ),
            phones: StereoOutputState(
                leftDBTenths: phonesLeft,
                rightDBTenths: phonesRight
            )
        )
    }
}
