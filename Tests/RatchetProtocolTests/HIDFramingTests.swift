import Foundation
import Testing
@testable import RatchetProtocol

@Test func framingRoundTripsBoundaryLengths() throws {
    for length in [0, 1, 51, 52, 53, 4095, 4096] {
        let payload = Data((0..<length).map { UInt8($0 % 251) })
        let reports = try HIDFraming.fragment(messageID: 42, payload: payload)
        var reassembler = HIDFraming.Reassembler()
        var result: HIDFraming.CompleteMessage?
        for report in reports {
            result = try reassembler.push(report) ?? result
        }
        #expect(result == .init(messageID: 42, payload: payload))
    }
}

@Test func framingAcceptsReportIDPrefix() throws {
    let report = try #require(HIDFraming.fragment(messageID: 7, payload: Data([1, 2, 3])).first)
    var prefixed = Data([0])
    prefixed.append(report)
    var reassembler = HIDFraming.Reassembler()
    #expect(try reassembler.push(prefixed)?.payload == Data([1, 2, 3]))
}

@Test func framingRejectsNonZeroPadding() throws {
    var report = try #require(HIDFraming.fragment(messageID: 7, payload: Data([1])).first)
    report[13] = 1
    var reassembler = HIDFraming.Reassembler()
    #expect(throws: HIDFraming.FrameError.invalidMetadata) {
        try reassembler.push(report)
    }
}

@Test func reconnectInTheMiddleOfHelloWaitsForNextMessage() throws {
    // Tail of the Hello captured from the stuck process after USB reconnect.
    var tail = Data([
        0x52, 0x48, 0x01, 0x02, 0x6d, 0x99, 0x01, 0x02,
        0x52, 0x00, 0x1e, 0x00, 0x10, 0x08, 0x18, 0x04,
        0x20, 0xf0, 0x01, 0x28, 0xf0, 0x01, 0x30, 0x80,
        0x20, 0x3a, 0x02, 0x00, 0x01, 0x30, 0xea, 0x28,
        0x3a, 0x08, 0x70, 0x6f, 0x77, 0x65, 0x72, 0x2d,
        0x6f, 0x6e,
    ])
    tail.append(Data(repeating: 0, count: HIDFraming.reportSize - tail.count))
    var reassembler = HIDFraming.Reassembler()
    #expect(try reassembler.push(tail) == nil)

    let payload = Data(repeating: 0xab, count: 82)
    let next = try HIDFraming.fragment(messageID: 0x996e, payload: payload)
    #expect(try reassembler.push(next[0]) == nil)
    #expect(try reassembler.push(next[1])?.payload == payload)
}

@Test func damagedFragmentDoesNotPoisonNextMessage() throws {
    var reassembler = HIDFraming.Reassembler()
    let frames = try HIDFraming.fragment(messageID: 10, payload: Data(repeating: 1, count: 82))
    #expect(try reassembler.push(frames[0]) == nil)
    var badTail = frames[1]
    badTail[63] = 1
    #expect(throws: HIDFraming.FrameError.invalidMetadata) { try reassembler.push(badTail) }
    #expect(try reassembler.push(frames[1]) == nil)
    #expect(try reassembler.push(frames[0]) == nil)
    #expect(try reassembler.push(frames[1])?.payload.count == 82)
}
