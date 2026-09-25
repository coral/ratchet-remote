import Foundation
import Testing
@testable import RMEControl

/// Models the DSP endpoint, including unrelated routing metadata in snapshots.
/// Tests exercise the controller's real write/refresh/ACK path without audio I/O.
private final class MixerTransport: UCXIIDSPTransport, @unchecked Sendable {
    var values: [UInt16: Int16] = [
        0x0008: 590, 0x3050: 0, 0x307a: 0,
        0x0500: -200, 0x0540: -200,
        0x0600: -400, 0x0640: -400,
        0x0680: -300, 0x06c0: -300,
        // Mic sends to Main/Phones and ADAT return to ADAT: all off.
        0x2000: -650, 0x2180: -650, 0x230c: -650,
        // Mic send into ADAT 1/2 stays at its existing level.
        0x2300: -100,
        0x0000: 0,
    ]
    var frames: [[UInt32]] = []
    var writes: [[UInt32]] = []
    var ignoreGainWrites = false
    var ignoreOutputWrites = false
    var omitFromSnapshot: Set<UInt16> = []
    var identity = UCXIIDeviceIdentity(serial: 123, product: 0x3f82)
    var identityReads = 0
    var responseDelay: TimeInterval = 0
    private var responseReadyAt: TimeInterval = 0

    func identify() -> UCXIIDeviceIdentity {
        identityReads += 1
        return identity
    }

    func writeDSP(_ words: [UInt32]) throws {
        #expect(identityReads == 1)
        _ = try UCXIIDSPWrite(words)
        writes.append(words)
        for word in words {
            let (register, value) = RMEWordCodec.decode(word)
            switch register {
            case RMERegisterMap.refresh:
                responseReadyAt = ProcessInfo.processInfo.systemUptime + responseDelay
                frames.append(values.keys.sorted().filter { !omitFromSnapshot.contains($0) }.map {
                    RMEWordCodec.encodeWrite(register: $0, value: values[$0]!)
                })
            case RMERegisterMap.poll: break
            case RMERegisterMap.micLine1Gain where ignoreGainWrites: break
            case _ where ignoreOutputWrites && RMERegisterMap.outputVolumeRegisters.contains(register): break
            default: values[register] = value
            }
        }
    }

    func triggerDSPRead() {}
    func readDSP() -> [UInt32] {
        guard ProcessInfo.processInfo.systemUptime >= responseReadyAt else { return [] }
        return frames.isEmpty ? [] : frames.removeFirst()
    }

    var controlWrites: [UInt32] {
        writes.flatMap { $0 }.filter {
            let register = RMEWordCodec.decode($0).register
            return register != RMERegisterMap.poll && register != RMERegisterMap.refresh
        }
    }
}

@Test func knobBurstDoesNotRequestSnapshotsOrPretendReadbackWasReceived() async throws {
    let mixer = MixerTransport()
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()
    let initialRefreshCount = mixer.writes.flatMap { $0 }.filter {
        RMEWordCodec.decode($0).register == RMERegisterMap.refresh
    }.count
    for target: Int16 in [-210, -220, -230, -240] {
        let presented = try await controller.setVolume(dbTenths: target, output: .main)
        #expect(presented?.main.dbTenths == target)
    }
    #expect(await controller.currentState()?.main.dbTenths == -200)
    #expect(mixer.writes.flatMap { $0 }.filter {
        RMEWordCodec.decode($0).register == RMERegisterMap.refresh
    }.count == initialRefreshCount)
    let verified = try await controller.refreshState()
    #expect(verified.main.dbTenths == -240)
    #expect(await controller.currentState()?.main.dbTenths == -240)
}

@Test func slowSnapshotDoesNotBlockNewKnobWritesOrEraseNewerTargets() async throws {
    let mixer = MixerTransport()
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()
    mixer.responseDelay = 0.180
    let refresh = Task { try await controller.refreshState() }
    try await Task.sleep(for: .milliseconds(30))
    let start = ProcessInfo.processInfo.systemUptime
    let submitted = try await controller.setVolume(dbTenths: -250, output: .main)
    _ = try await controller.setMicLine1Gain(dbTenths: 0)
    let mutedPhones = try await controller.setVolume(dbTenths: -650, output: .phones)
    #expect(ProcessInfo.processInfo.systemUptime - start < 0.100)
    #expect(submitted?.main.dbTenths == -250)
    #expect(mutedPhones?.micLine1Muted == true)
    #expect(mutedPhones?.phones.muted == true)
    let staleSnapshotPresentation = try await refresh.value
    #expect(staleSnapshotPresentation.main.dbTenths == -250)
    #expect(staleSnapshotPresentation.micLine1Muted)
    #expect(staleSnapshotPresentation.phones.muted)
    #expect(await controller.currentState()?.main.dbTenths == -200)
    let verified = try await controller.refreshState()
    #expect(verified.main.dbTenths == -250)
    #expect(await controller.currentState()?.main.dbTenths == -250)
}

@Test func disconnectCancelsSuspendedSnapshotWithoutWaitingForTimeout() async throws {
    let mixer = MixerTransport()
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()
    mixer.responseDelay = 1
    let refresh = Task { try await controller.refreshState() }
    try await Task.sleep(for: .milliseconds(30))
    let start = ProcessInfo.processInfo.systemUptime
    await controller.disconnect()
    #expect(ProcessInfo.processInfo.systemUptime - start < 0.100)
    do {
        _ = try await refresh.value
        Issue.record("Old snapshot must not survive a disconnect")
    } catch RMEControlError.notConnected {}
    #expect(await controller.currentState() == nil)
}

@Test func identityIsCheckedBeforeSendingAnyDSPCommands() async throws {
    for identity in [
        UCXIIDeviceIdentity(serial: 456, product: 0x3f82),
        UCXIIDeviceIdentity(serial: 123, product: 0x3f80),
    ] {
        let mixer = MixerTransport()
        mixer.identity = identity
        let controller = UCXIIController(connection: mixer, serial: 123)
        do {
            _ = try await controller.refreshState()
            Issue.record("A mismatched device must not be controlled")
        } catch RMEControlError.deviceIdentityMismatch(let serial, let product) {
            #expect(serial == identity.serial)
            #expect(product == identity.product)
        }
        #expect(mixer.writes.isEmpty)
    }
}

@Test func classCompliantModeCannotUseTheUSBControlProfile() async throws {
    let mixer = MixerTransport()
    mixer.values[0x307a] = 1
    let controller = UCXIIController(connection: mixer, serial: 123)
    do {
        _ = try await controller.refreshState()
        Issue.record("Class-compliant mode is outside this control profile")
    } catch RMEControlError.unsupportedDeviceMode(let mode) {
        #expect(mode == 1)
    }
    do {
        _ = try await controller.setMicLine1Gain(dbTenths: 0)
        Issue.record("No mic write is allowed without a supported device snapshot")
    } catch RMEControlError.notConnected {}
    #expect(mixer.controlWrites.isEmpty)
}

@Test func ignoredOutputWriteIsPresentedImmediatelyThenReconciled() async throws {
    let mixer = MixerTransport()
    mixer.ignoreOutputWrites = true
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()
    let presented = try await controller.setVolume(dbTenths: -650, output: .main)
    #expect(presented?.main.muted == true)
    #expect(await controller.currentState()?.main.muted == false)
    let reconciled = try await controller.refreshState()
    #expect(reconciled.main.muted == false)
}

@Test func ackSequenceWrapsAndDisconnectForgetsObservedState() async throws {
    let mixer = MixerTransport()
    // Unknown registers still receive ACKs, without becoming control writes.
    mixer.frames = (0..<18).map { _ in [RMEWordCodec.encodeWrite(register: 0x2000, value: -650)] }
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()
    let acks = mixer.writes.flatMap { $0 }.map(RMEWordCodec.decode).filter { $0.register == 0x3dff }
    #expect(acks.map(\.value) == (0..<19).map { Int16($0 % 16) })
    await controller.disconnect()
    #expect(await controller.currentState() == nil)
    #expect(await controller.isConnected == false)
}

@Test func micMuteRoundTripPreservesAllSubmixSends() async throws {
    let mixer = MixerTransport()
    let before = mixer.values
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()

    let muted = try #require(try await controller.setMicLine1Gain(dbTenths: 0))
    #expect(muted.micLine1Muted)
    #expect(mixer.values == before.merging([0x0008: 0]) { _, new in new })
    let live = try #require(try await controller.setMicLine1Gain(dbTenths: 590))
    #expect(!live.micLine1Muted)
    #expect(mixer.values == before)
    #expect(mixer.controlWrites == [
        RMEWordCodec.encodeWrite(register: 0x0008, value: 0),
        RMEWordCodec.encodeWrite(register: 0x0008, value: 590),
    ])
}

@Test func ignoredMicWriteIsPresentedImmediatelyThenReconciled() async throws {
    let mixer = MixerTransport()
    mixer.ignoreGainWrites = true
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()
    let presented = try await controller.setMicLine1Gain(dbTenths: 0)
    #expect(presented?.micLine1Muted == true)
    #expect(await controller.currentState()?.micLine1GainDBTenths == 590)
    let reconciled = try await controller.refreshState()
    #expect(reconciled.micLine1Muted == false)
}

@Test func mainFollowsControlRoomAssignmentAndPhonesKeepsWorkspacePair() async throws {
    let mixer = MixerTransport()
    let controller = UCXIIController(connection: mixer, serial: 123)
    _ = try await controller.refreshState()
    _ = try await controller.setVolume(dbTenths: -220, output: .main)
    #expect(mixer.values[0x0500] == -220)
    #expect(mixer.values[0x0540] == -220)

    mixer.values[0x3050] = 2 // Main moves to Analog 5/6.
    let state = try await controller.refreshState()
    #expect(state.main.dbTenths == -400)
    #expect(state.mainOutputPair == 2)
    _ = try await controller.setVolume(dbTenths: -250, output: .main)
    _ = try await controller.setVolume(dbTenths: -650, output: .phones)
    #expect(mixer.values[0x0500] == -220)
    #expect(mixer.values[0x0540] == -220)
    #expect(mixer.values[0x0600] == -250)
    #expect(mixer.values[0x0640] == -250)
    #expect(mixer.values[0x0680] == -650)
    #expect(mixer.values[0x06c0] == -650)
    #expect(mixer.controlWrites.map { RMEWordCodec.decode($0).register } == [
        0x0500, 0x0540, 0x0600, 0x0640, 0x0680, 0x06c0,
    ])
}

@Test func refreshAcknowledgesOldFramesWithoutUsingThemAsFreshState() async throws {
    let mixer = MixerTransport()
    mixer.frames = [[RMEWordCodec.encodeWrite(register: 0x0008, value: 0)]]
    let controller = UCXIIController(connection: mixer, serial: 123)
    let state = try await controller.refreshState()
    #expect(state.micLine1GainDBTenths == 590)
    let commands = mixer.writes.flatMap { $0 }.map(RMEWordCodec.decode)
    #expect(commands.map(\.register) == [0x3dff, 0x3e04, 0x3dff])
    #expect(commands.first?.value == 0)
    #expect(commands.last?.value == 1)

    mixer.omitFromSnapshot = [0x0008]
    do {
        _ = try await controller.refreshState(timeout: 0.03)
        Issue.record("Cached gain must not complete a fresh snapshot")
    } catch RMEControlError.snapshotTimedOut(let missing) {
        #expect(missing == [0x0008])
    }
}

@Test(arguments: [Int16(-1), 10, 32767])
func unsupportedMainAssignmentNeverWritesAnOutput(pair: Int16) async throws {
    let mixer = MixerTransport()
    mixer.values[0x3050] = pair
    let controller = UCXIIController(connection: mixer, serial: 123)
    do {
        _ = try await controller.refreshState()
        Issue.record("Invalid Main assignment must be reported")
    } catch RMEControlError.invalidMainAssignment(let actual) {
        #expect(actual == pair)
    }
    do {
        _ = try await controller.setVolume(dbTenths: -200, output: .main)
        Issue.record("No output should be written without a resolved Main assignment")
    } catch RMEControlError.notConnected {}
    #expect(mixer.controlWrites.isEmpty)
}

@Test func dspPayloadUsesWordCountAndZeroPadding() throws {
    let word = RMEWordCodec.encodeWrite(register: 0x0008, value: 0)
    let payload = try UCXIIDSPWrite([word])
    #expect(payload.wordCount == 1)
    #expect(payload.staging.count * MemoryLayout<UInt32>.size == 512)
    #expect(payload.staging.first == word)
    #expect(payload.staging.dropFirst().allSatisfy { $0 == 0 })
}

@Test(arguments: [UInt16(0x0000), 0x0048, 0x0502, 0x2000, 0x2180, 0x2300, 0x230c, 0x4000, 0x4300, 0x430c, 0x3050])
func writeBoundaryRejectsInputMuteOtherGainsRoutingAndAssignments(register: UInt16) {
    #expect(throws: RMEControlError.self) {
        try UCXIIDSPWrite([RMEWordCodec.encodeWrite(register: register, value: 0)])
    }
}

@Test func corruptDSPWordsCannotChangeState() {
    var accumulator = UCXIIStateAccumulator()
    let valid = RMEWordCodec.encodeWrite(register: 0x0008, value: 590)
    let corruptedChanged = accumulator.update(words: [0, valid ^ 0x8000_0000])
    #expect(!corruptedChanged)
    #expect(accumulator.values.isEmpty)
    let validChanged = accumulator.update(words: [valid])
    #expect(validChanged)
    #expect(accumulator.values[0x0008] == 590)
}
