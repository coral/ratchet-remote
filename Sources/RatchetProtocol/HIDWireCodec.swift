import Foundation
import SwiftProtobuf

public struct HIDWireCodec: Sendable {
    private var inbound = HIDFraming.Reassembler()

    public init() {}

    public static func encodeHostMessage(
        messageID: UInt16,
        message: Ratchet_V1_HostToDevice
    ) throws -> [Data] {
        try HIDFraming.fragment(messageID: messageID, payload: message.serializedData())
    }

    public mutating func pushDeviceRead(_ report: Data) throws -> Ratchet_V1_DeviceToHost? {
        guard let complete = try inbound.push(report) else { return nil }
        return try Ratchet_V1_DeviceToHost(serializedBytes: complete.payload)
    }
}
