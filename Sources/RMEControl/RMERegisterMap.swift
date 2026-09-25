import Foundation

public enum RMERegisterMap {
    public static let minimumDBTenths: Int16 = -650
    public static let maximumHardwareDBTenths: Int16 = 60
    public static let minimumMicGainDBTenths: Int16 = 0
    public static let maximumMicGainDBTenths: Int16 = 750

    public static let micLine1Gain: UInt16 = 0x0008
    public static let controlRoomMain: UInt16 = 0x3050
    public static let classCompliantMode: UInt16 = 0x307a

    public static let mainLeftVolume: UInt16 = 0x0500
    public static let mainRightVolume: UInt16 = 0x0540

    public static let phonesLeftVolume: UInt16 = 0x0680
    public static let phonesRightVolume: UInt16 = 0x06c0

    static let poll: UInt16 = 0x3dff
    static let refresh: UInt16 = 0x3e04
    static let refreshValue: Int16 = 0x67cd

    // Fixed mono slots from rme-volume/baked/protocol.xml. A submix is an
    // output destination, not a collection of input faders to move together.
    static let outputVolumeRegisters: Set<UInt16> = Set((0..<20).map {
        UInt16(0x0500 + $0 * 0x40)
    })
    public static let stateRegisters: Set<UInt16> = outputVolumeRegisters.union([
        micLine1Gain, controlRoomMain, classCompliantMode,
    ])

    static func volumeRegisters(for output: RMEOutput, mainPair: Int16) throws -> (UInt16, UInt16) {
        switch output {
        case .main:
            guard (0..<10).contains(mainPair) else {
                throw RMEControlError.invalidMainAssignment(mainPair)
            }
            let left = UInt16(0x0500 + Int(mainPair) * 2 * 0x40)
            return (left, left + 0x40)
        case .phones:
            // Phones1Chan=6 in the supplied TotalMix workspace. The protocol
            // does not define a live Phones assignment register.
            return (phonesLeftVolume, phonesRightVolume)
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
            guard word != 0, !word.nonzeroBitCount.isMultiple(of: 2) else { continue }
            let decoded = RMEWordCodec.decode(word)
            guard RMERegisterMap.stateRegisters.contains(decoded.register) else { continue }
            if values[decoded.register] != decoded.value {
                values[decoded.register] = decoded.value
                changed = true
            }
        }
        return changed
    }

    var missingRegisters: [UInt16] {
        var required: Set<UInt16> = [
            RMERegisterMap.micLine1Gain, RMERegisterMap.controlRoomMain,
            RMERegisterMap.classCompliantMode,
            RMERegisterMap.phonesLeftVolume, RMERegisterMap.phonesRightVolume,
        ]
        if let pair = values[RMERegisterMap.controlRoomMain],
           let registers = try? RMERegisterMap.volumeRegisters(for: .main, mainPair: pair) {
            required.formUnion([registers.0, registers.1])
        }
        return required.filter { values[$0] == nil }.sorted()
    }

    func state(serial: UInt64) -> UCXIIState? {
        guard values[RMERegisterMap.classCompliantMode] == 0,
              let pair = values[RMERegisterMap.controlRoomMain],
              let registers = try? RMERegisterMap.volumeRegisters(for: .main, mainPair: pair),
              let micGain = values[RMERegisterMap.micLine1Gain],
              let mainLeft = values[registers.0],
              let mainRight = values[registers.1],
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
            ),
            mainOutputPair: pair
        )
    }
}
