import Foundation
import SwiftProtobuf

public enum MutationKind: String, Equatable, Sendable {
    case configure = "Configure"
    case setHaptics = "SetHaptics"
    case ledFrame = "LedFrame"
    case displayFrame = "DisplayFrame"
    case disableOutputs = "DisableOutputs"
    case recalibrateMotor = "RecalibrateMotor"
    case provisionUsbPd = "ProvisionUsbPd"

    public init?(command: Ratchet_V1_HostToDevice.OneOf_Command) {
        switch command {
        case .configure: self = .configure
        case .setHaptics: self = .setHaptics
        case .ledFrame: self = .ledFrame
        case .displayFrame: self = .displayFrame
        case .disableOutputs: self = .disableOutputs
        case .recalibrateMotor: self = .recalibrateMotor
        case .provisionUsbPd: self = .provisionUsbPd
        case .enterBootloader, .ping, .requestStatus, .requestUsbPdStatus: return nil
        }
    }

    var isCoalescibleUIFrame: Bool {
        self == .ledFrame || self == .displayFrame
    }
}

public struct HelloTransition: Equatable, Sendable {
    public let first: Bool
    public let bootChanged: Bool
}

public struct MutationCompletion: Equatable, Sendable {
    public let kind: MutationKind
    public let sequence: UInt32
}

public struct SessionUpdate: Sendable {
    public var message: Ratchet_V1_DeviceToHost?
    public var hello: HelloTransition?
    public var completion: MutationCompletion?
    public var authorityLost: Bool
    public var outbound: [Data]

    static let empty = SessionUpdate(
        message: nil,
        hello: nil,
        completion: nil,
        authorityLost: false,
        outbound: []
    )
}

public enum RatchetSessionError: Error, LocalizedError, Sendable {
    case protocolVersion(actual: UInt32, expected: UInt32)
    case queueFull(maximum: Int)
    case retryExhausted(kind: MutationKind, sequence: UInt32, retries: UInt8, protobufBytes: Int, reportCount: Int)
    case commandRejected(kind: MutationKind, sequence: UInt32, code: Ratchet_V1_AckCode, detail: String)

    public var errorDescription: String? {
        switch self {
        case .protocolVersion(let actual, let expected):
            "device protocol version \(actual) does not match host version \(expected)"
        case .queueFull(let maximum):
            "state-changing command queue is full (\(maximum) pending commands)"
        case .retryExhausted(let kind, let sequence, let retries, let bytes, let reports):
            "\(kind.rawValue) command \(sequence) was not acknowledged after \(retries) retries (\(bytes) protobuf bytes across \(reports) HID reports)"
        case .commandRejected(let kind, let sequence, let code, let detail):
            "\(kind.rawValue) command \(sequence) was rejected with code \(code.rawValue): \(detail)"
        }
    }
}

/// Reliable command state for one open Ratchet boot session.
public struct RatchetSession: Sendable {
    public static let commandAckTimeout: TimeInterval = 0.5
    public static let commandMaxRetries: UInt8 = 3
    public static let maximumQueuedMutations = 16
    public static let heartbeatInterval: TimeInterval = 0.5

    private struct InFlightMutation: Sendable {
        let kind: MutationKind
        let sequence: UInt32
        let protobufBytes: Int
        let reports: [Data]
        var retriesSent: UInt8
        var retryDeadline: TimeInterval
    }

    private var wire = HIDWireCodec()
    public private(set) var commandSequence: UInt32 = 0
    private var messageID: UInt16 = 0
    public private(set) var bootID: UInt64?
    private var mutationQueue: [Ratchet_V1_HostToDevice.OneOf_Command] = []
    private var inFlight: InFlightMutation?
    private var lastHeartbeat: TimeInterval

    public init(now: TimeInterval) {
        lastHeartbeat = now
    }

    public var hasSeenHello: Bool { bootID != nil }
    public var pendingMutationKind: MutationKind? { inFlight?.kind }
    public var pendingMutationSequence: UInt32? { inFlight?.sequence }
    public var pendingRetryCount: UInt8? { inFlight?.retriesSent }
    public var queuedMutationCount: Int { mutationQueue.count }

    public func hasPendingMutation(_ kind: MutationKind) -> Bool {
        inFlight?.kind == kind || mutationQueue.contains { MutationKind(command: $0) == kind }
    }

    public mutating func send(
        _ command: Ratchet_V1_HostToDevice.OneOf_Command,
        now: TimeInterval
    ) throws -> [Data] {
        if let kind = MutationKind(command: command) {
            if kind.isCoalescibleUIFrame,
               let index = mutationQueue.indices.reversed().prefix(while: {
                   MutationKind(command: mutationQueue[$0])?.isCoalescibleUIFrame == true
               }).first(where: { MutationKind(command: mutationQueue[$0]) == kind }) {
                mutationQueue[index] = command
                return []
            }
            guard mutationQueue.count < Self.maximumQueuedMutations else {
                throw RatchetSessionError.queueFull(maximum: Self.maximumQueuedMutations)
            }
            mutationQueue.append(command)
            return try startNextMutation(now: now)
        }
        let sequence = commandSequence &+ 1
        let encoded = try encode(command, sequence: sequence)
        commandSequence = sequence
        return encoded.reports
    }

    public mutating func tick(now: TimeInterval, hostMicros: UInt64) throws -> [Data] {
        var reports = try pollTransactions(now: now)
        if hasSeenHello, now - lastHeartbeat >= Self.heartbeatInterval {
            var ping = Ratchet_V1_Ping()
            ping.hostMicros = hostMicros
            reports.append(contentsOf: try send(.ping(ping), now: now))
            lastHeartbeat = now
        }
        return reports
    }

    public mutating func pushDeviceRead(_ report: Data, now: TimeInterval) throws -> SessionUpdate {
        guard let message = try wire.pushDeviceRead(report) else { return .empty }
        return try processDeviceMessage(message, now: now)
    }

    public mutating func processDeviceMessage(
        _ message: Ratchet_V1_DeviceToHost,
        now: TimeInterval
    ) throws -> SessionUpdate {
        guard message.protocolVersion == RatchetProtocolConstants.protocolVersion else {
            throw RatchetSessionError.protocolVersion(
                actual: message.protocolVersion,
                expected: RatchetProtocolConstants.protocolVersion
            )
        }

        var update = SessionUpdate(
            message: message,
            hello: nil,
            completion: nil,
            authorityLost: false,
            outbound: []
        )
        switch message.event {
        case .hello(let hello):
            let first = bootID == nil
            let bootChanged = bootID.map { $0 != hello.bootID } ?? false
            if bootChanged { resetTransactions() }
            if first || bootChanged || sequenceIsNewer(hello.lastHostSequence, than: commandSequence) {
                commandSequence = hello.lastHostSequence
            }
            bootID = hello.bootID
            update.hello = HelloTransition(first: first, bootChanged: bootChanged)

        case .ready(let ready):
            if let result = try completeMutation(sequence: ready.configurationSequence, now: now) {
                update.completion = result.0
                update.outbound = result.1
            }

        case .ack(let ack):
            if let kind = matchingMutationKind(sequence: ack.commandSequence) {
                if ack.code == .notConfigured {
                    resetTransactions()
                    update.authorityLost = true
                } else if ack.code != .ok {
                    // A negative acknowledgement is a terminal result for these
                    // exact command bytes. Do not let the retry timer resend it.
                    resetTransactions()
                    throw RatchetSessionError.commandRejected(
                        kind: kind,
                        sequence: ack.commandSequence,
                        code: ack.code,
                        detail: ack.detail
                    )
                } else if kind == .disableOutputs {
                    update.completion = MutationCompletion(kind: kind, sequence: ack.commandSequence)
                    resetTransactions()
                    update.authorityLost = true
                }
                if !update.authorityLost,
                   let result = try completeMutation(sequence: ack.commandSequence, now: now) {
                    update.completion = result.0
                    update.outbound = result.1
                }
            }

        case .fault:
            resetTransactions()
            update.authorityLost = true

        case .usbPdProvisionResult(let result):
            if let completed = try completeMutation(sequence: result.commandSequence, now: now) {
                update.completion = completed.0
                update.outbound = completed.1
            }

        case .input, .pong, .status, .usbPdStatus, .none:
            break
        }
        return update
    }

    public mutating func discardPendingMutations() {
        resetTransactions()
    }

    private mutating func pollTransactions(now: TimeInterval) throws -> [Data] {
        guard var transaction = inFlight else { return try startNextMutation(now: now) }
        guard now >= transaction.retryDeadline else { return [] }
        guard transaction.retriesSent < Self.commandMaxRetries else {
            throw RatchetSessionError.retryExhausted(
                kind: transaction.kind,
                sequence: transaction.sequence,
                retries: transaction.retriesSent,
                protobufBytes: transaction.protobufBytes,
                reportCount: transaction.reports.count
            )
        }
        transaction.retriesSent &+= 1
        transaction.retryDeadline = now + Self.commandAckTimeout
        inFlight = transaction
        return transaction.reports
    }

    private mutating func startNextMutation(now: TimeInterval) throws -> [Data] {
        guard inFlight == nil, !mutationQueue.isEmpty else { return [] }
        let command = mutationQueue[0]
        guard let kind = MutationKind(command: command) else { return [] }
        let sequence = commandSequence &+ 1
        let encoded = try encode(command, sequence: sequence)
        mutationQueue.removeFirst()
        commandSequence = sequence
        inFlight = InFlightMutation(
            kind: kind,
            sequence: sequence,
            protobufBytes: encoded.protobufBytes,
            reports: encoded.reports,
            retriesSent: 0,
            retryDeadline: now + Self.commandAckTimeout
        )
        return encoded.reports
    }

    private mutating func completeMutation(
        sequence: UInt32,
        now: TimeInterval
    ) throws -> (MutationCompletion, [Data])? {
        guard let transaction = inFlight, transaction.sequence == sequence else { return nil }
        inFlight = nil
        return (
            MutationCompletion(kind: transaction.kind, sequence: transaction.sequence),
            try startNextMutation(now: now)
        )
    }

    private func matchingMutationKind(sequence: UInt32) -> MutationKind? {
        guard inFlight?.sequence == sequence else { return nil }
        return inFlight?.kind
    }

    private mutating func resetTransactions() {
        inFlight = nil
        mutationQueue.removeAll(keepingCapacity: true)
    }

    private mutating func encode(
        _ command: Ratchet_V1_HostToDevice.OneOf_Command,
        sequence: UInt32
    ) throws -> (reports: [Data], protobufBytes: Int) {
        let envelope = makeEnvelope(command, sequence: sequence)
        let payload = try envelope.serializedData()
        let nextMessageID = messageID &+ 1
        let reports = try HIDFraming.fragment(messageID: nextMessageID, payload: payload)
        messageID = nextMessageID
        return (reports, payload.count)
    }

    private func makeEnvelope(
        _ command: Ratchet_V1_HostToDevice.OneOf_Command,
        sequence: UInt32
    ) -> Ratchet_V1_HostToDevice {
        var envelope = Ratchet_V1_HostToDevice()
        envelope.protocolVersion = RatchetProtocolConstants.protocolVersion
        envelope.sequence = sequence
        envelope.command = command
        return envelope
    }
}

public func sequenceIsNewer(_ candidate: UInt32, than reference: UInt32) -> Bool {
    let distance = candidate &- reference
    return distance != 0 && distance < 0x8000_0000
}
