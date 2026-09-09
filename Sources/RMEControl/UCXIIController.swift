import CoreFoundation
import Foundation
import IOKit

private let rmeDriverClass = "de_rme_audio_dkusb"
private let ucxIIProductID: UInt64 = 0x3f82
private let triggerDSPReadSelector: UInt32 = 12
private let writeDSPSelector: UInt32 = 18
private let readDSPSelector: UInt32 = 19
private let dspWriteWords = 128
private let dspReadWords = 256
private let dspReadRetryInterval: TimeInterval = 0.020
private let snapshotRetryInterval: TimeInterval = 0.250

private final class RMEConnection {
    let port: io_connect_t

    init(port: io_connect_t) {
        self.port = port
    }

    deinit {
        IOServiceClose(port)
    }

    func writeDSP(_ words: [UInt32]) throws {
        guard (1...dspWriteWords).contains(words.count) else {
            throw RMEControlError.invalidWriteCount(words.count)
        }
        var staging = [UInt32](repeating: 0, count: dspWriteWords)
        staging.replaceSubrange(0..<words.count, with: words)
        var scalarCount = UInt64(words.count)
        let status: kern_return_t = staging.withUnsafeBytes { structure in
            withUnsafePointer(to: &scalarCount) { count in
                IOConnectCallMethod(
                    port,
                    writeDSPSelector,
                    count,
                    1,
                    structure.baseAddress,
                    structure.count,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }
        }
        try checkIO(status, operation: "writing UCX II DSP registers")
    }

    func triggerDSPRead() throws {
        // Mode 2 requests DSP input without starting TotalMix's level-meter
        // transfers, which this client does not consume.
        var mode: UInt32 = 2
        let status = withUnsafePointer(to: &mode) { pointer in
            IOConnectCallMethod(
                port,
                triggerDSPReadSelector,
                nil,
                0,
                pointer,
                MemoryLayout<UInt32>.size,
                nil,
                nil,
                nil,
                nil
            )
        }
        try checkIO(status, operation: "triggering a UCX II DSP read")
    }

    func readDSP() throws -> [UInt32] {
        var buffer = [UInt32](repeating: 0, count: dspReadWords)
        var outputSize = buffer.count * MemoryLayout<UInt32>.size
        let status = buffer.withUnsafeMutableBytes { output in
            IOConnectCallStructMethod(
                port,
                readDSPSelector,
                nil,
                0,
                output.baseAddress,
                &outputSize
            )
        }
        try checkIO(status, operation: "reading UCX II DSP registers")
        guard outputSize <= buffer.count * MemoryLayout<UInt32>.size,
              outputSize.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw RMEControlError.invalidReadSize(outputSize)
        }
        let count = outputSize / MemoryLayout<UInt32>.size
        if count == dspReadWords, buffer.allSatisfy({ $0 == 0 }) { return [] }
        return Array(buffer.prefix(count))
    }
}

private func checkIO(_ status: kern_return_t, operation: String) throws {
    guard status == KERN_SUCCESS else {
        throw RMEControlError.io(operation: operation, status: status)
    }
}

private struct RMEDevice {
    let service: io_service_t
    let serial: UInt64

    func release() {
        IOObjectRelease(service)
    }
}

private func registryString(service: io_service_t, key: String) throws -> String {
    guard let property = IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
    ), let value = property.takeRetainedValue() as? String else {
        throw RMEControlError.missingRegistryProperty(key)
    }
    return value
}

private func registryParentNumber(service: io_service_t, key: String) throws -> UInt64 {
    let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    guard let value = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key as CFString,
        kCFAllocatorDefault,
        options
    ) as? NSNumber else {
        throw RMEControlError.missingRegistryProperty(key)
    }
    return value.uint64Value
}

private func selectUCXII(serial wantedSerial: UInt64?) throws -> RMEDevice {
    guard let matching = IOServiceNameMatching(rmeDriverClass) else {
        throw RMEControlError.noDevice(serial: wantedSerial)
    }
    var iterator: io_iterator_t = 0
    try checkIO(
        IOServiceGetMatchingServices(0, matching, &iterator),
        operation: "enumerating RME DriverKit services"
    )
    defer { IOObjectRelease(iterator) }

    var matches: [RMEDevice] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        do {
            let productID = try registryParentNumber(service: service, key: "idProduct")
            let uid = try registryString(service: service, key: "device UID")
            guard let suffix = uid.split(separator: "-").last,
                  let serial = UInt64(suffix) else {
                throw RMEControlError.malformedDeviceUID(uid)
            }
            if productID == ucxIIProductID, wantedSerial == nil || serial == wantedSerial {
                matches.append(RMEDevice(service: service, serial: serial))
            } else {
                IOObjectRelease(service)
            }
        } catch {
            IOObjectRelease(service)
            throw error
        }
    }
    guard !matches.isEmpty else { throw RMEControlError.noDevice(serial: wantedSerial) }
    guard matches.count == 1 else {
        matches.forEach { $0.release() }
        throw RMEControlError.multipleDevices
    }
    return matches[0]
}

/// Owns the single serialized RME DriverKit user client used by the app.
/// No two DSP reads or writes can overlap because all access is actor-isolated.
public actor UCXIIController {
    private var connection: RMEConnection?
    private var serial: UInt64?
    private var pollSequence: UInt8 = 0
    private var readArmed = false
    private var accumulator = UCXIIStateAccumulator()

    public init() {}

    public var isConnected: Bool { connection != nil }

    @discardableResult
    public func connect(serial wantedSerial: UInt64? = nil) throws -> UCXIIState {
        disconnect()
        let device = try selectUCXII(serial: wantedSerial)
        defer { device.release() }
        var port: io_connect_t = 0
        try checkIO(
            IOServiceOpen(device.service, mach_task_self_, 0, &port),
            operation: "opening the RME driver user client"
        )
        connection = RMEConnection(port: port)
        serial = device.serial
        pollSequence = 0
        readArmed = false
        accumulator = UCXIIStateAccumulator()
        do {
            return try refreshState(timeout: 2.0, drainFirst: true)
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        connection = nil
        serial = nil
        readArmed = false
        accumulator = UCXIIStateAccumulator()
    }

    public func currentState() -> UCXIIState? {
        guard let serial else { return nil }
        return accumulator.state(serial: serial)
    }

    /// Polls one live DSP response, returning state only when a relevant register changed.
    public func poll(timeout: TimeInterval = 0.075) throws -> UCXIIState? {
        let connection = try requireConnection()
        try armRead(connection)
        guard let words = try waitForRead(connection, deadline: ProcessInfo.processInfo.systemUptime + timeout) else {
            return nil
        }
        guard accumulator.update(words: words), let serial else { return nil }
        return accumulator.state(serial: serial)
    }

    /// Requests a complete TotalMix state dump and makes the device authoritative.
    public func refreshState(timeout: TimeInterval = 2.0, drainFirst: Bool = false) throws -> UCXIIState {
        let connection = try requireConnection()
        if drainFirst { try drain(connection) }
        var refreshed = UCXIIStateAccumulator()
        try armRead(connection)
        try connection.writeDSP([
            RMEWordCodec.encodeWrite(register: RMERegisterMap.refresh, value: RMERegisterMap.refreshValue),
        ])

        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timeout
        var nextRequest = started + snapshotRetryInterval
        while ProcessInfo.processInfo.systemUptime < deadline {
            try armRead(connection)
            if ProcessInfo.processInfo.systemUptime >= nextRequest {
                // A stalled transfer can lose the first snapshot packet while
                // the driver recovers. Request it again within the same timeout.
                try connection.writeDSP([
                    RMEWordCodec.encodeWrite(register: RMERegisterMap.refresh, value: RMERegisterMap.refreshValue),
                ])
                nextRequest = ProcessInfo.processInfo.systemUptime + snapshotRetryInterval
            }
            guard let words = try waitForRead(connection, deadline: min(deadline, nextRequest)) else { continue }
            _ = accumulator.update(words: words)
            _ = refreshed.update(words: words)
            if let serial, let state = refreshed.state(serial: serial) {
                accumulator = refreshed
                return state
            }
        }
        throw RMEControlError.snapshotTimedOut(missingRegisters: refreshed.missingRegisters)
    }

    public func setMicLine1Gain(dbTenths: Int16) throws -> UCXIIState? {
        let value = min(
            max(dbTenths, RMERegisterMap.minimumMicGainDBTenths),
            RMERegisterMap.maximumMicGainDBTenths
        )
        try write([(RMERegisterMap.micLine1Gain, value)])
        accumulator.set(register: RMERegisterMap.micLine1Gain, value: value)
        return currentState()
    }

    public func setVolume(dbTenths: Int16, output: RMEOutput) throws -> UCXIIState? {
        let value = min(max(dbTenths, RMERegisterMap.minimumDBTenths), output.maximumDBTenths)
        let registers = RMERegisterMap.volumeRegisters(for: output)
        try write([(registers.0, value), (registers.1, value)])
        accumulator.set(register: registers.0, value: value)
        accumulator.set(register: registers.1, value: value)
        return currentState()
    }

    private func write(_ values: [(UInt16, Int16)]) throws {
        let connection = try requireConnection()
        try connection.writeDSP(values.map { RMEWordCodec.encodeWrite(register: $0.0, value: $0.1) })
    }

    private func requireConnection() throws -> RMEConnection {
        guard let connection else { throw RMEControlError.notConnected }
        return connection
    }

    private func drain(_ connection: RMEConnection) throws {
        for _ in 0..<64 {
            if try connection.readDSP().isEmpty { break }
        }
        readArmed = false
    }

    private func armRead(_ connection: RMEConnection) throws {
        guard !readArmed else { return }
        try connection.triggerDSPRead()
        readArmed = true
    }

    private func waitForRead(_ connection: RMEConnection, deadline: TimeInterval) throws -> [UInt32]? {
        var nextTrigger = ProcessInfo.processInfo.systemUptime + dspReadRetryInterval
        while ProcessInfo.processInfo.systemUptime < deadline {
            let words = try connection.readDSP()
            if !words.isEmpty {
                readArmed = false
                try connection.writeDSP([
                    RMEWordCodec.encodeWrite(register: RMERegisterMap.poll, value: Int16(pollSequence & 0x0f)),
                ])
                pollSequence = (pollSequence &+ 1) & 0x0f
                return words
            }
            if ProcessInfo.processInfo.systemUptime >= nextTrigger {
                // The driver's asynchronous USB read can time out or stall.
                // Trigger again so it can clear the stall and arm a new read.
                try connection.triggerDSPRead()
                nextTrigger = ProcessInfo.processInfo.systemUptime + dspReadRetryInterval
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }
}
