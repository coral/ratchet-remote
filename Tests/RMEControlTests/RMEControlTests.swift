import Testing
@testable import RMEControl

@Test func registerWriteEncodingMatchesCapturedPackets() {
    #expect(RMEWordCodec.encodeWrite(register: 0x0680, value: 0) == 0x0680_0000)
    #expect(RMEWordCodec.encodeWrite(register: 0x06c0, value: 0) == 0x86c0_0000)
    #expect(RMEWordCodec.encodeWrite(register: 0x3e04, value: 0x67cd) == 0xbe04_67cd)
    #expect(RMEWordCodec.encodeWrite(register: 0x3dff, value: 15) == 0x3dff_000f)
    #expect(RMEWordCodec.encodeWrite(register: RMERegisterMap.micLine1Gain, value: 0) == 0x0008_0000)
    #expect(RMEWordCodec.encodeWrite(register: RMERegisterMap.micLine1Gain, value: 580) == 0x8008_0244)
}

@Test func stateUsesQuieterStereoSideAndFloorAsMute() throws {
    var accumulator = UCXIIStateAccumulator()
    _ = accumulator.update(words: [
        RMEWordCodec.encodeWrite(register: RMERegisterMap.micLine1Gain, value: 580),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.mainLeftVolume, value: -200),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.mainRightVolume, value: -210),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.phonesLeftVolume, value: -650),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.phonesRightVolume, value: -650),
    ])
    let state = try #require(accumulator.state(serial: 123))
    #expect(state.main.dbTenths == -210)
    #expect(!state.main.muted)
    #expect(state.main.hasLevelMismatch)
    #expect(state.phones.isAtFloor)
    #expect(state.phones.muted)
    #expect(!state.micLine1Muted)
    #expect(state.micLine1GainDBTenths == 580)
}

@Test func zeroMicGainIsPracticalMute() throws {
    var accumulator = UCXIIStateAccumulator()
    _ = accumulator.update(words: [
        RMEWordCodec.encodeWrite(register: RMERegisterMap.micLine1Gain, value: 0),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.mainLeftVolume, value: -200),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.mainRightVolume, value: -200),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.phonesLeftVolume, value: -300),
        RMEWordCodec.encodeWrite(register: RMERegisterMap.phonesRightVolume, value: -300),
    ])
    let state = try #require(accumulator.state(serial: 123))
    #expect(state.micLine1Muted)
    #expect(state.micLine1GainDBTenths == 0)
}
