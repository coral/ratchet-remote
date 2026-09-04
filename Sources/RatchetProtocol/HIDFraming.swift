import Foundation

public enum RatchetProtocolConstants {
    public static let protocolVersion: UInt32 = 1
    public static let vendorID = 0x303a
    public static let productID = 0x4004
    public static let usagePage = 0xff00
    public static let usage = 0x0001
}

public enum HIDFraming {
    public static let reportSize = 64
    public static let headerSize = 12
    public static let payloadSize = reportSize - headerSize
    public static let maximumMessageSize = 4096

    private static let magic: [UInt8] = [0x52, 0x48] // "RH"
    private static let version: UInt8 = 1
    private static let firstFlag: UInt8 = 1 << 0
    private static let lastFlag: UInt8 = 1 << 1
    private static let knownFlags = firstFlag | lastFlag

    public struct CompleteMessage: Equatable, Sendable {
        public let messageID: UInt16
        public let payload: Data
    }

    public enum FrameError: Error, Equatable, LocalizedError, Sendable {
        case invalidReportSize(Int)
        case messageTooLarge(actual: Int, maximum: Int)
        case invalidMagic
        case unsupportedVersion(UInt8)
        case invalidMetadata
        case outOfOrder(expected: UInt8, actual: UInt8)
        case wrongMessage(expected: UInt16, actual: UInt16)

        public var errorDescription: String? {
            switch self {
            case .invalidReportSize(let size): "HID report has \(size) bytes; expected 64 or a 65-byte report-ID-prefixed read"
            case .messageTooLarge(let actual, let maximum): "message has \(actual) bytes; maximum is \(maximum)"
            case .invalidMagic: "invalid HID frame magic"
            case .unsupportedVersion(let version): "unsupported HID framing version \(version)"
            case .invalidMetadata: "invalid fragment metadata"
            case .outOfOrder(let expected, let actual): "expected fragment \(expected), received \(actual)"
            case .wrongMessage(let expected, let actual): "fragment belongs to message \(actual), expected \(expected)"
            }
        }
    }

    public static func fragment(messageID: UInt16, payload: Data) throws -> [Data] {
        guard payload.count <= maximumMessageSize else {
            throw FrameError.messageTooLarge(actual: payload.count, maximum: maximumMessageSize)
        }

        let fragmentCount = max(payload.count, 1).quotientAndRemainder(dividingBy: payloadSize)
        let count = fragmentCount.quotient + (fragmentCount.remainder == 0 ? 0 : 1)
        guard count <= Int(UInt8.max) else {
            throw FrameError.messageTooLarge(actual: payload.count, maximum: maximumMessageSize)
        }

        return (0..<count).map { index in
            let start = index * payloadSize
            let end = min(start + payloadSize, payload.count)
            let bytes = start < end ? payload[start..<end] : Data.SubSequence()
            var report = Data(repeating: 0, count: reportSize)
            report[0] = magic[0]
            report[1] = magic[1]
            report[2] = version
            report[3] = (index == 0 ? firstFlag : 0) | (index + 1 == count ? lastFlag : 0)
            report[4] = UInt8(truncatingIfNeeded: messageID)
            report[5] = UInt8(truncatingIfNeeded: messageID >> 8)
            report[6] = UInt8(index)
            report[7] = UInt8(count)
            report[8] = UInt8(truncatingIfNeeded: payload.count)
            report[9] = UInt8(truncatingIfNeeded: payload.count >> 8)
            report[10] = UInt8(bytes.count)
            report.replaceSubrange(headerSize..<(headerSize + bytes.count), with: bytes)
            return report
        }
    }

    public struct Reassembler: Sendable {
        private struct Assembly: Sendable {
            let messageID: UInt16
            let fragmentCount: UInt8
            var nextFragment: UInt8
            let totalLength: Int
            var bytes: Data
        }

        private var assembly: Assembly?

        public init() {}

        public mutating func reset() {
            assembly = nil
        }

        public mutating func push(_ input: Data) throws -> CompleteMessage? {
            let report: Data
            if input.count == reportSize {
                report = input
            } else if input.count == reportSize + 1, input.first == 0 {
                // Materialize a fresh zero-based Data value; Data slices preserve
                // their original indices and would make fixed header offsets trap.
                report = Data(input.dropFirst())
            } else {
                assembly = nil
                throw FrameError.invalidReportSize(input.count)
            }

            let header: Header
            do {
                header = try Header(report: report)
            } catch {
                assembly = nil
                throw error
            }

            if header.isFirst {
                assembly = Assembly(
                    messageID: header.messageID,
                    fragmentCount: header.fragmentCount,
                    nextFragment: 0,
                    totalLength: header.totalLength,
                    bytes: Data()
                )
            }

            guard var current = assembly else {
                throw FrameError.invalidMetadata
            }
            guard current.messageID == header.messageID else {
                assembly = nil
                throw FrameError.wrongMessage(expected: current.messageID, actual: header.messageID)
            }
            guard current.nextFragment == header.fragmentIndex,
                  current.fragmentCount == header.fragmentCount,
                  current.totalLength == header.totalLength else {
                assembly = nil
                throw FrameError.outOfOrder(expected: current.nextFragment, actual: header.fragmentIndex)
            }

            current.bytes.append(report[headerSize..<(headerSize + header.payloadLength)])
            current.nextFragment &+= 1
            assembly = current

            guard header.isLast else { return nil }
            guard current.bytes.count == current.totalLength else {
                assembly = nil
                throw FrameError.invalidMetadata
            }
            assembly = nil
            return CompleteMessage(messageID: current.messageID, payload: current.bytes)
        }

        private struct Header {
            let flags: UInt8
            let messageID: UInt16
            let fragmentIndex: UInt8
            let fragmentCount: UInt8
            let totalLength: Int
            let payloadLength: Int

            var isFirst: Bool { flags & firstFlag != 0 }
            var isLast: Bool { flags & lastFlag != 0 }

            init(report: Data) throws {
                guard report[0] == magic[0], report[1] == magic[1] else { throw FrameError.invalidMagic }
                guard report[2] == version else { throw FrameError.unsupportedVersion(report[2]) }
                flags = report[3]
                messageID = UInt16(report[4]) | UInt16(report[5]) << 8
                fragmentIndex = report[6]
                fragmentCount = report[7]
                totalLength = Int(report[8]) | Int(report[9]) << 8
                payloadLength = Int(report[10])

                let expectedCount = (max(totalLength, 1) + payloadSize - 1) / payloadSize
                let offset = Int(fragmentIndex) * payloadSize
                let expectedPayload = min(max(totalLength - offset, 0), payloadSize)
                let paddingStart = headerSize + payloadLength
                guard flags & ~knownFlags == 0,
                      report[11] == 0,
                      fragmentCount > 0,
                      fragmentIndex < fragmentCount,
                      Int(fragmentCount) == expectedCount,
                      payloadLength <= payloadSize,
                      payloadLength == expectedPayload,
                      totalLength <= maximumMessageSize,
                      isFirst == (fragmentIndex == 0),
                      isLast == (fragmentIndex &+ 1 == fragmentCount),
                      report[paddingStart...].allSatisfy({ $0 == 0 }) else {
                    throw FrameError.invalidMetadata
                }
            }
        }
    }
}
