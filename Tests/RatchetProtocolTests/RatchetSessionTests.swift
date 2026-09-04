import Foundation
import SwiftProtobuf
import Testing
@testable import RatchetProtocol

private func decodeHostMessages(_ reports: [Data]) throws -> [Ratchet_V1_HostToDevice] {
    var reassembler = HIDFraming.Reassembler()
    var messages: [Ratchet_V1_HostToDevice] = []
    for report in reports {
        if let complete = try reassembler.push(report) {
            messages.append(try Ratchet_V1_HostToDevice(serializedBytes: complete.payload))
        }
    }
    return messages
}

@Test func sessionSerializesMutationsAndStartsNextAfterAck() throws {
    var session = RatchetSession(now: 0)
    let first = try session.send(.ledFrame(Ratchet_V1_LedFrame()), now: 0)
    let queued = try session.send(.displayFrame(Ratchet_V1_DisplayFrame()), now: 0)
    #expect(first.isEmpty == false)
    #expect(queued.isEmpty)

    var ack = Ratchet_V1_Ack()
    ack.commandSequence = 1
    ack.code = .ok
    var message = Ratchet_V1_DeviceToHost()
    message.protocolVersion = 1
    message.event = .ack(ack)
    let update = try session.processDeviceMessage(message, now: 0.1)
    #expect(update.completion == MutationCompletion(kind: .ledFrame, sequence: 1))
    #expect(try decodeHostMessages(update.outbound).first?.sequence == 2)
}

@Test func sessionRetriesExactReports() throws {
    var session = RatchetSession(now: 0)
    let original = try session.send(.ledFrame(Ratchet_V1_LedFrame()), now: 0)
    #expect(try session.tick(now: 0.49, hostMicros: 0).isEmpty)
    #expect(try session.tick(now: 0.5, hostMicros: 0) == original)
}

@Test func helloSynchronizesWrappedSequence() throws {
    var session = RatchetSession(now: 0)
    var hello = Ratchet_V1_Hello()
    hello.bootID = 10
    hello.lastHostSequence = UInt32.max
    var message = Ratchet_V1_DeviceToHost()
    message.protocolVersion = 1
    message.event = .hello(hello)
    _ = try session.processDeviceMessage(message, now: 0)

    let reports = try session.send(.requestStatus(Ratchet_V1_RequestStatus()), now: 0)
    #expect(try decodeHostMessages(reports).first?.sequence == 0)
}

@Test func serialNumberComparisonUsesRFC1982Ordering() {
    #expect(sequenceIsNewer(0, than: UInt32.max))
    #expect(!sequenceIsNewer(UInt32.max, than: 0))
    #expect(!sequenceIsNewer(3, than: 3))
}

@Test func negativeAckStopsExactCommandRetries() throws {
    var session = RatchetSession(now: 0)
    _ = try session.send(.ledFrame(Ratchet_V1_LedFrame()), now: 0)

    var ack = Ratchet_V1_Ack()
    ack.commandSequence = 1
    ack.code = .invalidConfiguration
    ack.detail = "bad frame"
    var message = Ratchet_V1_DeviceToHost()
    message.protocolVersion = 1
    message.event = .ack(ack)

    #expect(throws: RatchetSessionError.self) {
        try session.processDeviceMessage(message, now: 0.1)
    }
    #expect(session.pendingMutationKind == nil)
    #expect(try session.tick(now: 1, hostMicros: 1).isEmpty)
}

@Test func encodingFailureDoesNotConsumeCommandSequence() throws {
    var session = RatchetSession(now: 0)
    var frame = Ratchet_V1_DisplayFrame()
    frame.present = true
    var operation = Ratchet_V1_DrawOp()
    var text = Ratchet_V1_Text()
    text.value = String(repeating: "x", count: HIDFraming.maximumMessageSize + 1)
    operation.operation = .text(text)
    frame.operations = [operation]

    #expect(throws: HIDFraming.FrameError.self) {
        try session.send(.displayFrame(frame), now: 0)
    }
    #expect(session.commandSequence == 0)
    #expect(session.pendingMutationKind == nil)
    #expect(session.queuedMutationCount == 1)
}
