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
